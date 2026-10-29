import Foundation
import Testing
@testable import PhiceCore

@Test func replayTicksBetweenFramesSoTimeoutsFireWhenNoFramesCome() {
    // A tap, then a second touch the phone reported only as it landed and as it lifted.
    var pad = Pad()
    pad.tap()
    let touch = Touch(id: 1, x: 400, y: 200, radius: 20, phase: .began, t: pad.t + 0.1)
    var lifted = touch
    lifted.phase = .ended
    lifted.t = touch.t + 0.3
    let frames = pad.frames
        + [TouchFrame(t: touch.t, touches: [touch]), TouchFrame(t: lifted.t, touches: [lifted])]
    var recogniser = Recogniser(settings: TrackpadSettings(), geometry: Replay.defaultGeometry)
    #expect(Replay.run(frames, through: &recogniser) == click() + [press, release])
}

@Test func jsonLinesRoundTripAndABadLineSaysWhichItIs() throws {
    let events: [PadEvent] = [.move(dx: 1.5, dy: -2, t: 0.25), .shortcut(.spaceLeft), .drop(.cut)]
    let text = try Replay.encodeLines(events)
    #expect(text.split(separator: "\n").count == 3)
    #expect(try Replay.decodeLines(PadEvent.self, from: Data(text.utf8)) == events)
    #expect(try Replay.decodeLines(PadEvent.self, from: Data((text + "\n\n").utf8)) == events)

    #expect {
        try Replay.decodeLines(PadEvent.self, from: Data((text + "{\"nope\":1}\n").utf8))
    } throws: { ($0 as? Replay.BadLine)?.line == 4 }
}
