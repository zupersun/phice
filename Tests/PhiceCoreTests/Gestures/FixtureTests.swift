import Foundation
import Testing
@testable import PhiceCore

/// The golden sessions in `Fixtures/`: scripted touches (`<name>.frames.jsonl`), the events they
/// must replay to (`<name>.events.jsonl`) and, when not the Mac's defaults, the settings
/// (`<name>.settings.json`). The same files run through `swift run phice-replay`. After a
/// deliberate behaviour change, regenerate them and read the diff, since every changed line is one:
///
///     PHICE_WRITE_FIXTURES=1 swift test --filter writeFixtures
enum Fixture: String, CaseIterable, Sendable {
    case tap, doubleTap, twoFingerTap, cornerClick, tapDrag, threeFingerDrag, scrollMomentumStop
    case swipe3, swipe4, pinch, restingThumb, copyDrop, copyCancel
    // Contact-size shapes measured on an iPhone 17.
    case rampTap, restThenPress, firmTap, firmHold, thumbRoll, movingRise

    var settings: TrackpadSettings {
        var s = TrackpadSettings()
        switch self {
        case .cornerClick: s.secondaryClick = .bottomRight
        case .threeFingerDrag:
            s.threeFingerDrag = true
            s.swipeSpaces = [.four]
            s.missionControl = [.four]
        case .swipe4: s.swipeSpaces = [.four]; s.missionControl = [.four]
        default: break
        }
        return s
    }

    /// Everything but motion the session must produce: what a reader of the golden checks first.
    var actions: [PadEvent] {
        switch self {
        case .tap: click()
        case .doubleTap: click(.left, 1) + click(.left, 2)
        case .twoFingerTap: click(.right)
        case .cornerClick: click(.right)
        case .tapDrag: click() + [press, release]
        case .threeFingerDrag: [press, release]
        case .scrollMomentumStop: [.momentumStop] + click()
        case .swipe3: [.shortcut(.spaceRight), .shortcut(.missionControl)]
        case .swipe4: [.shortcut(.spaceLeft), .shortcut(.missionControl)]
        case .pinch: [.shortcut(.zoomIn), .shortcut(.zoomIn), .shortcut(.zoomOut)]
        case .restingThumb: click()
        case .rampTap, .firmTap: click()
        case .restThenPress, .firmHold: [press, release]
        case .thumbRoll: click()
        case .movingRise: []
        case .copyDrop: click() + [press, .freeze(true), .drop(.copy), .freeze(false)]
        case .copyCancel: click() + [press, .freeze(true), .freeze(false), release]
        }
    }

    func play(_ pad: inout Pad) {
        let three: [(UInt16, Double, Double)] = [(1, 350, 200), (2, 400, 190), (3, 450, 200)]
        switch self {
        case .tap:
            pad.tap()
        case .doubleTap:
            pad.tap()
            pad.wait(0.12)
            pad.tap()
        case .twoFingerTap:
            pad.tap(fingers: 2)
        case .cornerClick:
            pad.tap(840, 380)
        case .tapDrag:
            pad.tap()
            pad.wait(0.1)
            pad.land(1, 400, 200)
            pad.hold(0.2)
            pad.move([1], 80, 30, frames: 12)
            pad.lift(1)
        case .threeFingerDrag:
            pad.land(three)
            pad.move([1, 2, 3], 90, -40, frames: 12)
            pad.lift(1, 2, 3)
        case .scrollMomentumStop:
            pad.land([(1, 400, 160), (2, 440, 170)])
            pad.move([1, 2], 0, 120, frames: 10)
            pad.lift(1, 2)
            pad.wait(0.5)
            pad.tap(300, 250)
        case .swipe3:
            pad.land(three)
            pad.move([1, 2, 3], -120, 0, frames: 10)
            pad.lift(1, 2, 3)
            pad.wait(0.6)
            pad.land(three)
            pad.move([1, 2, 3], 0, -120, frames: 10)
            pad.lift(1, 2, 3)
        case .swipe4:
            let four = three + [(4, 500, 210)]
            pad.land(four)
            pad.move([1, 2, 3, 4], 120, 0, frames: 10)
            pad.lift(1, 2, 3, 4)
            pad.wait(0.6)
            pad.land(four)
            pad.move([1, 2, 3, 4], 0, -120, frames: 10)
            pad.lift(1, 2, 3, 4)
        case .pinch:
            pad.land([(1, 400, 200), (2, 460, 200)])
            pad.scale([1, 2], by: 2, frames: 36)
            pad.lift(1, 2)
            pad.wait(0.6)
            pad.land([(1, 300, 200), (2, 500, 200)])
            pad.scale([1, 2], by: 0.6, frames: 12)
            pad.lift(1, 2)
        case .restingThumb:
            pad.land(1, 300, 340, r: steps(4))
            pad.hold(0.25)
            pad.tap(500, 150)
            pad.hold(0.1)
            pad.lift(1)
        case .rampTap:
            pad.land(1, 400, 200, r: steps(1))
            pad.hold(0.03)
            pad.press(1, to: steps(2))
            pad.hold(0.06)
            pad.lift(1)
        case .restThenPress:
            pad.land(1, 400, 200, r: steps(1))
            pad.hold(0.02)
            pad.press(1, to: steps(2))
            pad.hold(0.38)
            pad.press(1, to: steps(3))
            pad.hold(0.5)
            pad.lift(1)
        case .firmTap:
            pad.land(1, 400, 200, r: steps(3))
            pad.hold(0.1)
            pad.lift(1)
        case .firmHold:
            pad.land(1, 400, 200, r: steps(3))
            pad.hold(0.4)
            pad.lift(1)
        case .thumbRoll:
            pad.land(1, 300, 340)
            pad.hold(0.08)
            pad.press(1, to: steps(4))
            pad.hold(0.05)
            pad.press(1, to: steps(5))
            pad.hold(0.05)
            pad.press(1, to: steps(6))
            pad.hold(0.1)
            pad.tap(500, 150)
            pad.lift(1)
        case .movingRise:
            pad.land(1, 500, 200, r: steps(1))
            pad.move([1], 80, 10, frames: 12, radius: steps(3))
            pad.hold(0.4)
            pad.lift(1)
        case .copyDrop, .copyCancel:
            pad.tap()
            pad.wait(0.1)
            pad.land(1, 600, 200)
            pad.hold(0.2)
            pad.land(2, 640, 220)
            pad.hold(0.05)
            pad.move([1, 2], self == .copyDrop ? -500 : -150, 20, frames: 20)
            pad.lift(1, 2)
        }
    }

    func url(_ kind: String, in dir: URL) -> URL { dir.appending(path: "\(rawValue).\(kind)") }
}

private func fixtures() throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
}

@Test(arguments: Fixture.allCases)
func fixtureReplaysToItsGoldenEvents(_ fixture: Fixture) throws {
    let dir = try fixtures()
    let frames = try Replay.decodeLines(TouchFrame.self,
                                        from: Data(contentsOf: fixture.url("frames.jsonl", in: dir)))
    let expected = try Replay.decodeLines(PadEvent.self,
                                          from: Data(contentsOf: fixture.url("events.jsonl", in: dir)))
    let settingsFile = fixture.url("settings.json", in: dir)
    let settings = FileManager.default.fileExists(atPath: settingsFile.path)
        ? try JSONDecoder().decode(TrackpadSettings.self, from: Data(contentsOf: settingsFile))
        : TrackpadSettings()
    #expect(settings == fixture.settings)

    var recogniser = Recogniser(settings: settings, geometry: Replay.defaultGeometry)
    let events = Replay.run(frames, through: &recogniser)
    #expect(events == expected)
    #expect(events.filter(isAction) == fixture.actions)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PHICE_WRITE_FIXTURES"] != nil))
func writeFixtures() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures")
    for fixture in Fixture.allCases {
        var pad = Pad(fixture.settings)
        fixture.play(&pad)
        var recogniser = Recogniser(settings: fixture.settings, geometry: Replay.defaultGeometry)
        let events = Replay.run(pad.frames, through: &recogniser)
        #expect(events.filter(isAction) == fixture.actions, "\(fixture)")
        try Replay.encodeLines(pad.frames)
            .write(to: fixture.url("frames.jsonl", in: dir), atomically: true, encoding: .utf8)
        try Replay.encodeLines(events)
            .write(to: fixture.url("events.jsonl", in: dir), atomically: true, encoding: .utf8)
        if fixture.settings != TrackpadSettings() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fixture.settings).write(to: fixture.url("settings.json", in: dir))
        }
    }
}
