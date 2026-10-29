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

private func sample(_ phase: Touch.Phase, t: Double) -> TouchSample {
    TouchSample(key: 1, x: t * 100, y: 0, radius: 10, phase: phase, t: t)
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

@MainActor @Test func touchingThePadMarksTheLastTouch() {
    let model = AppModel(link: KeptLink())
    let loop = PadLoop(model: model)
    model.lastTouch = .distantPast
    loop.touches([sample(.began, t: 1)])
    #expect(model.lastTouch > .distantPast)
}

@MainActor @Test func thePadsLiveTouchesAreWhatIsDown() {
    let loop = PadLoop(model: AppModel(link: KeptLink()))
    loop.touches([sample(.began, t: 1)])
    #expect(loop.live.count == 1)
    loop.touches([sample(.ended, t: 1.1)])
    #expect(loop.live.isEmpty)
}
