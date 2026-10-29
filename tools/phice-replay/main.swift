import Foundation
import PhiceCore

// Replays a recorded session (one TouchFrame JSON per line) through the recogniser and prints the
// PadEvents as JSON lines. With --driver it carries on through the real MacDriver into a FakePoster
// and prints the poster calls instead, in the agent's `--fake-poster` log format (PosterLog). With
// --expect it diffs against a golden file and exits 1 on any difference. Settings and geometry are
// JSON files; they default to the Mac's defaults and an iPhone 17 Pro in landscape.

let usage = "usage: phice-replay session.jsonl [--settings s.json] [--geometry g.json] [--driver]"
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

var options: [String: String] = [:], paths: [String] = [], viaDriver = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    guard arg.hasPrefix("--") else {
        paths.append(arg)
        continue
    }
    if arg == "--driver" {
        viaDriver = true
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
let frames = lines(TouchFrame.self, paths[0])
let got: String
if viaDriver {
    let poster = FakePoster()
    let driver = MacDriver(poster: poster, settings: settings, curves: Curves.pointer,
                           scrollCurves: Curves.scroll)
    Replay.drive(frames, through: &recogniser, into: driver)
    got = PosterLog.lines(poster.calls)
} else {
    got = (try? Replay.encodeLines(Replay.run(frames, through: &recogniser))) ?? ""
}

guard let expectPath = options["--expect"] else {
    print(got, terminator: "")
    exit(0)
}
// Poster calls do not decode, so a poster log is compared as written; PadEvents re-encoded first,
// so a golden written by hand need not order its keys.
let wantLines = viaDriver
    ? String(decoding: read(expectPath), as: UTF8.self).split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    : ((try? Replay.encodeLines(lines(PadEvent.self, expectPath))) ?? "").split(separator: "\n")
        .map(String.init)
let gotLines = got.split(separator: "\n").map(String.init)
guard gotLines != wantLines else { exit(0) }

var report = ""
for i in 0 ..< max(gotLines.count, wantLines.count) where report.count < 4000 {
    let want = i < wantLines.count ? wantLines[i] : "(nothing)"
    let have = i < gotLines.count ? gotLines[i] : "(nothing)"
    guard want != have else { continue }
    report += "line \(i + 1):\n  expected \(want)\n  got      \(have)\n"
}
fail(report + "phice-replay: \(gotLines.count) lines, expected \(wantLines.count)", code: 1)
