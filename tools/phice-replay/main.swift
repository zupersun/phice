import Foundation
import PhiceCore

// Replays a recorded session (one TouchFrame JSON per line) through the recogniser and prints the
// PadEvents as JSON lines. With --expect it diffs them against a golden file instead and exits 1
// on any difference. Settings and geometry are JSON files; they default to the Mac's defaults and
// an iPhone 17 Pro in landscape.

let usage = "usage: phice-replay session.jsonl [--settings s.json] [--geometry g.json]"
    + " [--expect e.jsonl]"

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func read(_ path: String) -> Data {
    do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
        fail("phice-replay: cannot read \(path): \(error.localizedDescription)")
    }
}

func decode<T: Decodable>(_ type: T.Type, _ path: String?, or fallback: T) -> T {
    guard let path else { return fallback }
    do { return try JSONDecoder().decode(type, from: read(path)) } catch {
        fail("phice-replay: \(path): \(error)")
    }
}

func lines<T: Decodable>(_ type: T.Type, _ path: String) -> [T] {
    do { return try Replay.decodeLines(type, from: read(path)) } catch {
        fail("phice-replay: \(path): \(error)")
    }
}

var options: [String: String] = [:], paths: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    guard arg.hasPrefix("--") else {
        paths.append(arg)
        continue
    }
    guard ["--settings", "--geometry", "--expect"].contains(arg), let value = args.popFirst() else {
        fail(usage)
    }
    options[arg] = value
}
guard paths.count == 1 else { fail(usage) }

let settings = decode(TrackpadSettings.self, options["--settings"], or: TrackpadSettings())
let geometry = decode(PadGeometry.self, options["--geometry"], or: Replay.defaultGeometry)
var recogniser = Recogniser(settings: settings, geometry: geometry)
let events = Replay.run(lines(TouchFrame.self, paths[0]), through: &recogniser)
let got = (try? Replay.encodeLines(events)) ?? ""

guard let expectPath = options["--expect"] else {
    print(got, terminator: "")
    exit(0)
}
let expected = lines(PadEvent.self, expectPath)
guard events != expected else { exit(0) }

let gotLines = got.split(separator: "\n").map(String.init)
let wantLines = ((try? Replay.encodeLines(expected)) ?? "").split(separator: "\n").map(String.init)
var report = ""
for i in 0 ..< max(gotLines.count, wantLines.count) where report.count < 4000 {
    let want = i < wantLines.count ? wantLines[i] : "(nothing)"
    let have = i < gotLines.count ? gotLines[i] : "(nothing)"
    guard want != have else { continue }
    report += "event \(i + 1):\n  expected \(want)\n  got      \(have)\n"
}
fail(report + "phice-replay: \(gotLines.count) events, expected \(wantLines.count)", code: 1)
