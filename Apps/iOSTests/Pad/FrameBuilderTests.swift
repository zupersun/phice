import PhiceCore
import Testing
@testable import PhiceiOS

private func sample(_ key: UInt, _ phase: Touch.Phase, t: Double, x: Double = 0, radius: Double = 10)
    -> TouchSample {
    TouchSample(key: key, x: x, y: 0, radius: radius, phase: phase, t: t)
}

@Test func oneFingerGivesOneFramePerCoalescedSample() {
    var builder = FrameBuilder()
    let frames = builder.frames(from: [sample(7, .began, t: 1)])
        + builder.frames(from: [sample(7, .moved, t: 1.004, x: 2), sample(7, .moved, t: 1.008, x: 4)])
        + builder.frames(from: [sample(7, .ended, t: 1.012, x: 4)])
    #expect(frames.map(\.t) == [1, 1.004, 1.008, 1.012])
    #expect(frames.map { $0.touches.map(\.phase) } == [[.began], [.moved], [.moved], [.ended]])
    #expect(frames.map { $0.touches[0].x } == [0, 2, 4, 4])
    #expect(Set(frames.map { $0.touches[0].id }).count == 1)
    #expect(builder.live.isEmpty)
}

@Test func fingersSampledAtOneInstantShareAFrame() {
    var builder = FrameBuilder()
    let frames = builder.frames(from: [sample(1, .began, t: 1), sample(2, .began, t: 1)])
    #expect(frames.count == 1)
    #expect(Set(frames[0].touches.map(\.id)).count == 2)
}

@Test func aFingerNotSampledThisInstantIsCarriedAsStationary() {
    var builder = FrameBuilder()
    _ = builder.frames(from: [sample(1, .began, t: 1, x: 10, radius: 8),
                              sample(2, .began, t: 1, x: 50)])
    let frames = builder.frames(from: [sample(2, .moved, t: 1.01, x: 60)])
    #expect(frames.count == 1)
    let still = frames[0].touches.first { $0.x == 10 }
    #expect(frames[0].touches.count == 2)
    #expect(still?.phase == .stationary)
    #expect(still?.t == 1.01)
    #expect(still?.radius == 8)
}

@Test func samplesAlreadyBuiltAreSkipped() {
    // UIKit can call touchesBegan and then touchesMoved for one event, each with every finger.
    var builder = FrameBuilder()
    let landing = [sample(1, .began, t: 1), sample(2, .began, t: 1)]
    #expect(builder.frames(from: landing).count == 1)
    #expect(builder.frames(from: landing).isEmpty)
    let next = [sample(1, .moved, t: 1.01, x: 3), sample(2, .ended, t: 1.01)]
    #expect(builder.frames(from: next).count == 1)
    #expect(builder.frames(from: next).isEmpty)
    #expect(builder.live.count == 1)
}

@Test func aLiftedFingerIsInItsLiftFrameAndNoneAfter() {
    var builder = FrameBuilder()
    _ = builder.frames(from: [sample(1, .began, t: 1), sample(2, .began, t: 1)])
    #expect(builder.frames(from: [sample(1, .ended, t: 1.01)])[0].touches.count == 2)
    #expect(builder.frames(from: [sample(2, .moved, t: 1.02)])[0].touches.count == 1)
}

@Test func aNewTouchAtALiftedTouchesAddressGetsANewID() {
    // The key is the UITouch's address, which UIKit may reuse for the next finger.
    var builder = FrameBuilder()
    let first = builder.frames(from: [sample(1, .began, t: 1)])[0].touches[0].id
    _ = builder.frames(from: [sample(1, .ended, t: 1.1)])
    let second = builder.frames(from: [sample(1, .began, t: 1.2)])[0].touches[0].id
    #expect(first != second)
}

@Test func aTouchNeverSeenLandingIsIgnored() {
    var builder = FrameBuilder()
    #expect(builder.frames(from: [sample(9, .moved, t: 1), sample(9, .ended, t: 1.1)]).isEmpty)
}

@Test func aCancelStampedLikeTheLastSampleStillLifts() {
    var builder = FrameBuilder()
    _ = builder.frames(from: [sample(1, .began, t: 1)])
    let frames = builder.frames(from: [sample(1, .cancelled, t: 1)])
    #expect(frames.map { $0.touches.map(\.phase) } == [[.cancelled]])
    #expect(builder.live.isEmpty)
}
