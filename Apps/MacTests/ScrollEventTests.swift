import CoreGraphics
import PhiceCore
import Testing
@testable import Phice

private func field(_ event: CGEvent, _ f: CGEventField) -> Int64 { event.getIntegerValueField(f) }

@Test func pixelDeltasAreContinuousAndSignedPerAxis() {
    let e = ScrollEvent.make(dx: -3, dy: 12, phase: nil, momentum: nil)
    #expect(field(e, .scrollWheelEventIsContinuous) == 1)
    #expect(field(e, .scrollWheelEventPointDeltaAxis1) == 12)
    #expect(field(e, .scrollWheelEventPointDeltaAxis2) == -3)
    #expect(field(e, .scrollWheelEventScrollPhase) == 0)
    #expect(field(e, .scrollWheelEventMomentumPhase) == 0)
}

@Test func scrollPhasesUseCoreGraphicsValues() {
    let cases: [(ScrollPhase, Int64)] = [(.began, 1), (.changed, 2), (.ended, 4)]
    for (phase, raw) in cases {
        let e = ScrollEvent.make(dx: 0, dy: 1, phase: phase, momentum: nil)
        #expect(field(e, .scrollWheelEventScrollPhase) == raw)
        #expect(field(e, .scrollWheelEventMomentumPhase) == 0)
    }
}

@Test func momentumPhasesUseCoreGraphicsValues() {
    let cases: [(MomentumPhase, Int64)] = [(.begin, 1), (.continue, 2), (.end, 3)]
    for (momentum, raw) in cases {
        let e = ScrollEvent.make(dx: 0, dy: 1, phase: nil, momentum: momentum)
        #expect(field(e, .scrollWheelEventMomentumPhase) == raw)
        #expect(field(e, .scrollWheelEventScrollPhase) == 0)
    }
}

@Test func everyEventCarriesTheTagOfTheSignsPosted() {
    let e = ScrollEvent.make(dx: 0, dy: 5, phase: .changed, momentum: nil)
    #expect(field(e, .eventSourceUserData) == ScrollEvent.tag(dx: 0, dy: 5))
    #expect(ScrollEvent.tag(dx: 0, dy: 5) != ScrollEvent.tag(dx: 0, dy: -5))
    #expect(ScrollEvent.tag(dx: 2, dy: 0) != ScrollEvent.tag(dx: -2, dy: 0))
    #expect(ScrollEvent.isOurs(ScrollEvent.tag(dx: 1, dy: 1)))
    #expect(!ScrollEvent.isOurs(0))
}

@Test func aReverserIsNoticedWhenTheSignComesOutFlipped() {
    let watch = ScrollWatch()
    #expect(!watch.reversedY && !watch.reversedX)

    // Posted up (+5) and +4 across; came out down and left: a reverser negated both axes.
    watch.observe(ScrollEvent.make(dx: -4, dy: -5, phase: .changed, momentum: nil,
                                   tag: ScrollEvent.tag(dx: 4, dy: 5)))
    #expect(watch.reversedY && watch.reversedX)

    // The next one comes out as posted: the reverser has stopped.
    watch.observe(ScrollEvent.make(dx: 4, dy: 5, phase: .changed, momentum: nil))
    #expect(!watch.reversedY && !watch.reversedX)
}

@Test func theTrackpadsOwnEventsAndZeroDeltasChangeNothing() {
    let watch = ScrollWatch()
    watch.observe(ScrollEvent.make(dx: 0, dy: -5, phase: nil, momentum: nil,
                                   tag: ScrollEvent.tag(dx: 0, dy: 5)))
    #expect(watch.reversedY)

    let untagged = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: 7, wheel2: 0, wheel3: 0)!
    watch.observe(untagged)
    #expect(watch.reversedY)

    watch.observe(ScrollEvent.make(dx: 0, dy: 0, phase: .ended, momentum: nil,
                                   tag: ScrollEvent.tag(dx: 0, dy: 5)))
    #expect(watch.reversedY)
}

@Test func fractionsAccumulateInsteadOfVanishing() {
    var acc = ScrollAccumulator()
    #expect(acc.take(dx: 0, dy: 0.4).dy == 0)
    #expect(acc.take(dx: 0, dy: 0.4).dy == 0)
    #expect(acc.take(dx: 0, dy: 0.4).dy == 1)
    var down = ScrollAccumulator()
    #expect(down.take(dx: 0.6, dy: -0.6) == (0, 0))
    #expect(down.take(dx: 0.6, dy: -0.6) == (1, -1))
}

@Test func theSignIsPreFlippedWhileAReverserIsActive() {
    let poster = QuartzPoster(clipboard: Clipboard(pasteboard: .withUniqueName(),
                                                   store: ClipStore(directory: tempDirectory())))
    #expect(field(poster.scrollEvent(dx: 0, dy: 5, phase: .changed, momentum: nil)!,
                  .scrollWheelEventPointDeltaAxis1) == 5)

    poster.scrollWatch.observe(ScrollEvent.make(dx: 0, dy: -5, phase: nil, momentum: nil,
                                                tag: ScrollEvent.tag(dx: 0, dy: 5)))

    let corrected = poster.scrollEvent(dx: 0, dy: 5, phase: .changed, momentum: nil)!
    #expect(field(corrected, .scrollWheelEventPointDeltaAxis1) == -5)
    // The tag records what the poster meant, not what it sent, so the watch keeps seeing it correctly.
    #expect(field(corrected, .eventSourceUserData) == ScrollEvent.tag(dx: 0, dy: 5))
}
