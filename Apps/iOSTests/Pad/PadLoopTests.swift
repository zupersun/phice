import Foundation
import PhiceCore
import PhiceNet
import Testing
@testable import PhiceiOS

/// A link that keeps what it is given.
@MainActor private final class KeptLink: PhoneLink {
    var macs: [DiscoveredMac] = []
    var state = LinkState.connected
    var onChange: (@MainActor () -> Void)?
    var onMessage: (@MainActor (MacToPhone) -> Void)?
    var sent: [PhoneToMac] = []
    var frames: [[TouchFrame]] { sent.compactMap { if case let .frames(f) = $0 { f } else { nil } } }

    func start() {}
    func pair(with mac: DiscoveredMac) {}
    func send(_ message: PhoneToMac) { sent.append(message) }
    func forget() {}
}

private func sample(_ phase: Touch.Phase, t: Double, tolerance: Double = 0) -> TouchSample {
    TouchSample(key: 1, x: t * 100, y: 0, radius: 10, phase: phase, t: t, tolerance: tolerance)
}

@MainActor @Test func whileRecordingRawFramesGoToTheMacAboutEveryTenthOfASecond() {
    let link = KeptLink()
    let model = AppModel(link: link)
    let loop = PadLoop(model: model)
    model.recording = true
    loop.touches([sample(.began, t: 1)])
    loop.touches([sample(.moved, t: 1.05)])
    loop.tick(now: 1.06)
    #expect(link.frames.isEmpty)
    loop.tick(now: 1.1)
    #expect(link.frames.map(\.count) == [2])
    loop.tick(now: 1.2)
    #expect(link.frames.count == 1)

    model.recording = false
    loop.touches([sample(.moved, t: 1.25)])
    loop.tick(now: 1.4)
    #expect(link.frames.count == 1)
}

@MainActor @Test func framesStillWaitingWhenRecordingStopsAreSent() {
    let link = KeptLink()
    let model = AppModel(link: link)
    let loop = PadLoop(model: model)
    model.recording = true
    loop.touches([sample(.began, t: 1)])
    model.recording = false
    loop.tick(now: 1.01)
    #expect(link.frames.map(\.count) == [1])
}

@MainActor @Test func thePadsLiveTouchesAreWhatIsDown() {
    let loop = PadLoop(model: AppModel(link: KeptLink()))
    loop.touches([sample(.began, t: 1)])
    #expect(loop.live.count == 1)
    loop.touches([sample(.ended, t: 1.1)])
    #expect(loop.live.isEmpty)
}

@MainActor @Test func theFirstLandingWithATolerancePicksTheRadiusQuantum() {
    // majorRadius moves in steps of twice its tolerance; this phone's steps may not be the default's.
    let loop = PadLoop(model: AppModel(link: KeptLink()))
    let quantum = { loop.recogniser.tuning.force.quantum }
    let measured = quantum()
    loop.touches([sample(.began, t: 1, tolerance: 0)])
    loop.touches([sample(.ended, t: 1.1, tolerance: 5)])
    loop.touches([sample(.began, t: 2, tolerance: .nan)])
    loop.touches([sample(.ended, t: 2.1, tolerance: .infinity)])
    #expect(quantum() == measured)
    loop.touches([sample(.began, t: 3, tolerance: 7.5)])
    #expect(quantum() == 15)
    loop.touches([sample(.ended, t: 3.1, tolerance: 7.5)])
    loop.touches([sample(.began, t: 4, tolerance: 9)])
    #expect(quantum() == 15)
}

/// End to end through the real recogniser: a finger rests, presses a step harder, then lifts.
@MainActor @Test func aRealPressPlaysItsClickThenItsReleaseOnLift() {
    let loop = PadLoop(model: AppModel(link: KeptLink()))
    loop.size = CGSize(width: 874, height: 402)
    var played: [Haptic] = []
    loop.play = { played.append($0) }
    func still(_ phase: Touch.Phase, t: Double, steps: Double) -> TouchSample {
        TouchSample(key: 1, x: 400, y: 200, radius: steps * 12.139, phase: phase, t: t)
    }
    loop.touches([still(.began, t: 1, steps: 2)])
    for i in 1 ... 10 { loop.tick(now: 1 + Double(i) * 0.01) }
    #expect(played.isEmpty)
    loop.touches([still(.moved, t: 1.11, steps: 3)])
    #expect(played == [.press])
    loop.tick(now: 1.3)
    loop.touches([still(.ended, t: 1.4, steps: 0)])
    #expect(played == [.press, .release])
}
