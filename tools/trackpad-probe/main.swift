// Records the built-in trackpad's own event stream, so Phice's curves and momentum can be checked
// against the real thing. A macOS dev tool: never linked into the apps.
//
//   swift run trackpad-probe --out session.jsonl [--seconds 60] [--raw]
//   swift run trackpad-probe --fit momentum session.jsonl
//
// One JSON object per line. Times `t` are seconds on the mach uptime clock, from the HID event.
//   scroll:  px [dx, dy] pixels as posted, fixed / lines (the other CGEvent units), raw [dx, dy]
//            the HID event's unaccelerated counts, phase (1 began, 2 changed, 4 ended, 8 cancelled,
//            128 may begin), momentum (1 begin, 2 continue, 3 end), continuous
//   move:    d [dx, dy] screen points as posted, raw [dx, dy] unaccelerated counts
//   touches: (--raw) every finger the trackpad sees, from the private MultitouchSupport.framework
import CoreGraphics
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
    usage: trackpad-probe --out FILE.jsonl [--seconds N] [--raw]
           trackpad-probe --fit momentum FILE.jsonl
    """

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail(usage, code: 2) }
    defer { args.removeSubrange(i ... i + 1) }
    return args[i + 1]
}

if let what = value(after: "--fit") {
    guard what == "momentum", let path = args.first else { fail(usage, code: 2) }
    do { print(try fitMomentum(path: path)) } catch { fail("trackpad-probe: \(error)") }
    exit(0)
}

guard let out = value(after: "--out") else { fail(usage, code: 2) }
let seconds = value(after: "--seconds").map { Double($0) ?? -1 } ?? 60
let raw = args.contains("--raw")
args.removeAll { $0 == "--raw" }
guard args.isEmpty, seconds > 0 else { fail(usage, code: 2) }

guard CGPreflightListenEventAccess() else {
    _ = CGRequestListenEventAccess()
    fail("""
        trackpad-probe needs Input Monitoring to listen to the trackpad, and this terminal does not \
        have it. Open System Settings › Privacy & Security › Input Monitoring, switch on the app you \
        are running this from (macOS has just been asked to list it; add it with + if it is not \
        there), quit and reopen that app, then run this again.
        """)
}
guard FileManager.default.createFile(atPath: out, contents: nil),
      let file = FileHandle(forWritingAtPath: out)
else { fail("trackpad-probe: cannot write \(out)") }

recorder.start(file)
guard recorder.listen() else {
    fail("trackpad-probe: macOS refused the event tap even though Input Monitoring is granted. "
        + "Quit and reopen the terminal so the grant takes effect, then try again.")
}
if raw, let problem = recorder.listenToFingers() { fail("trackpad-probe: --raw: \(problem)") }

print("trackpad-probe: recording \(Int(seconds)) s to \(out). Use the trackpad: move, scroll, flick.")
CFRunLoopRunInMode(.defaultMode, seconds, false)
print("trackpad-probe: \(recorder.summary())")
