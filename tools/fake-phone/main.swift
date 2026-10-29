import Foundation
import PhiceCore
import PhiceNet

// Plays a recorded session to the Mac agent over the real link, so the whole system runs without a
// phone. Finds a Mac over Bonjour, pairs the first time (the Mac must be open for pairing), then
// feeds the fixture's frames through the recogniser at their recorded times, ticking at 120 Hz, and
// sends each batch of events the moment it is emitted. Prints what the Mac sends back.
// Exits 2 if no Mac connects within 30 s, 1 on bad input or a connection lost mid-play.

let usage = "usage: fake-phone --fixture NAME [--fixtures DIR] [--name \"Fake iPhone\"]"
setvbuf(stdout, nil, _IOLBF, 0)  // piped output shows up as it happens

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func read(_ url: URL) -> Data {
    do { return try Data(contentsOf: url) } catch { fail("fake-phone: \(error.localizedDescription)") }
}

var options: [String: String] = [:]
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    guard ["--fixture", "--fixtures", "--name"].contains(arg), let value = args.popFirst() else {
        fail(usage)
    }
    options[arg] = value
}
guard let fixture = options["--fixture"] else { fail(usage) }
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let fixtures = options["--fixtures"].map { URL(fileURLWithPath: $0) }
    ?? repo.appending(path: "Tests/PhiceCoreTests/Fixtures")

let framesURL = fixtures.appending(path: "\(fixture).frames.jsonl")
let frames: [TouchFrame]
do { frames = try Replay.decodeLines(TouchFrame.self, from: read(framesURL)) } catch {
    fail("fake-phone: \(framesURL.path): \(error)")
}
let settingsURL = fixtures.appending(path: "\(fixture).settings.json")
var settings = TrackpadSettings()
if FileManager.default.fileExists(atPath: settingsURL.path) {
    do {
        settings = try JSONDecoder().decode(TrackpadSettings.self, from: read(settingsURL))
    } catch {
        fail("fake-phone: \(settingsURL.path): \(error)")
    }
}

// MARK: Connect

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let store = FileKeyStore(url: support.appending(path: "Phice-fake-phone/keys.json"))
let link = NetworkPhoneLink(deviceName: options["--name"] ?? "Fake iPhone", keyStore: store)
var asked: Set<String> = []
var lastState = link.state
link.onMessage = { print("mac: \($0)") }
link.onChange = {
    if link.state != lastState {
        lastState = link.state
        print("fake-phone: \(link.state)")
    }
    // A Mac it holds a key for is reconnected to by the link itself; pair only when none is in sight.
    guard [.searching, .unreachable].contains(link.state), !link.macs.contains(where: \.paired),
          let mac = link.macs.first(where: { $0.pairingOpen && !asked.contains($0.id) }) else { return }
    asked.insert(mac.id)
    print("fake-phone: asking \(mac.name) to pair; click Allow there")
    link.pair(with: mac)
}
link.start()

let deadline = ContinuousClock.now + .seconds(30)
while link.state != .connected {
    guard ContinuousClock.now < deadline else {
        let held = store.peers.isEmpty ? "no key"
            : "a key for \(store.peers[0]) (delete \(store.url.path) if that Mac forgot this phone)"
        fail("fake-phone: no Mac connected within 30 s; saw \(link.macs.map(\.name)), holding \(held)",
             code: 2)
    }
    try await Task.sleep(for: .milliseconds(20))
}
print("fake-phone: connected; playing \(frames.count) frames of \(fixture)")
// What the phone app does too: the Mac's driver follows the settings the phone recognises with.
link.send(.settings(settings))

// MARK: Play

/// The same schedule as `Replay.run`, in real time: each frame at its own time, 120 Hz ticks
/// between, and a second of ticks after the last frame so pending clicks resolve.
var recogniser = Recogniser(settings: settings, geometry: Replay.defaultGeometry)
let start = ContinuousClock.now
let first = frames.first?.t ?? 0
var sent = 0

@MainActor func at(_ t: Double, _ step: () -> [PadEvent]) async {
    let due = start + .seconds(t - first)
    try? await Task.sleep(until: due, tolerance: .milliseconds(1), clock: .continuous)
    let events = step()
    guard !events.isEmpty else { return }
    link.send(.events(events))
    sent += events.count
}

@MainActor func ticks(after start: Double, before end: Double) async {
    var k = 1.0
    while start + k / Replay.tickRate < end {
        let t = start + k / Replay.tickRate
        await at(t) { recogniser.tick(now: t) }
        k += 1
    }
}

var previous: Double?
for frame in frames {
    if let previous { await ticks(after: previous, before: frame.t) }
    await at(frame.t) { recogniser.feed(frame) }
    previous = frame.t
}
if let previous { await ticks(after: previous, before: previous + 1) }

guard link.state == .connected else { fail("fake-phone: the connection dropped during playback") }
print("fake-phone: sent \(sent) events")
exit(0)
