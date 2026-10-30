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
    watch.observe(negated(ScrollEvent.make(dx: 4, dy: 5, phase: .changed, momentum: nil)))
    #expect(watch.reversedY && watch.reversedX)

    // The next one comes out as posted: the reverser has stopped.
    watch.observe(ScrollEvent.make(dx: 4, dy: 5, phase: .changed, momentum: nil))
    #expect(!watch.reversedY && !watch.reversedX)
}

@Test func theTrackpadsOwnEventsAndZeroDeltasChangeNothing() {
    let watch = ScrollWatch()
    watch.observe(negated(ScrollEvent.make(dx: 0, dy: 5, phase: nil, momentum: nil)))
    #expect(watch.reversedY)

    let untagged = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: 7, wheel2: 0, wheel3: 0)!
    watch.observe(untagged)
    #expect(watch.reversedY)

    watch.observe(ScrollEvent.make(dx: 0, dy: 0, phase: .ended, momentum: nil))
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

private func makePoster() -> QuartzPoster {
    QuartzPoster(clipboard: Clipboard(pasteboard: .withUniqueName(),
                                      store: ClipStore(directory: tempDirectory())))
}

@Test func theSignIsPreFlippedWhileAReverserIsActive() {
    let poster = makePoster()
    #expect(field(poster.scrollEvent(dx: 0, dy: 5, phase: .changed, momentum: nil)!,
                  .scrollWheelEventPointDeltaAxis1) == 5)

    poster.scrollWatch.observe(negated(ScrollEvent.make(dx: 0, dy: 5, phase: nil, momentum: nil)))

    let corrected = poster.scrollEvent(dx: 0, dy: 5, phase: .changed, momentum: nil)!
    #expect(field(corrected, .scrollWheelEventPointDeltaAxis1) == -5)
    // The tag says what was posted. The watch asks whether the sign that came out is the sign that
    // went in; asked about the sign that was meant instead, a working correction looks like no
    // reverser at all, the poster stops correcting, and the scroll flips direction every step.
    #expect(field(corrected, .eventSourceUserData) == ScrollEvent.tag(dx: 0, dy: -5))
}

// MARK: The reverser in the loop

/// Scrolling up by `dy` for `steps` events with a reverser that is on whenever `reverser(step)` says
/// so, and a watch that sees each event `lag` events late. Returns the sign each step finally had
/// when it reached the apps (+1 is the way it was meant to go).
private func scrollThroughReverser(steps: Int, lag: Int = 0, horizontal: Bool = false,
                                   reverser: (Int) -> Bool) -> [Int] {
    let poster = makePoster()
    var unseen: [CGEvent] = []
    var arrived: [Int] = []
    for step in 0..<steps {
        let phase: ScrollPhase = step == 0 ? .began : .changed
        let event = poster.scrollEvent(dx: horizontal ? 5 : 0, dy: horizontal ? 0 : 5,
                                       phase: phase, momentum: nil)!
        let delivered = reverser(step) ? negated(event) : event
        let axis: CGEventField = horizontal ? .scrollWheelEventPointDeltaAxis2
                                            : .scrollWheelEventPointDeltaAxis1
        arrived.append(field(delivered, axis) > 0 ? 1 : -1)
        unseen.append(delivered)
        if unseen.count > lag { poster.scrollWatch.observe(unseen.removeFirst()) }
    }
    return arrived
}

@Test func aSteadyScrollWithNoReverserNeverFlips() {
    #expect(scrollThroughReverser(steps: 30) { _ in false } == Array(repeating: 1, count: 30))
}

@Test func aSteadyReverserCostsOneWrongStepAndNoMore() {
    let arrived = scrollThroughReverser(steps: 30) { _ in true }
    #expect(arrived == [-1] + Array(repeating: 1, count: 29), "arrived \(arrived)")
}

@Test func aReverserThatStopsCostsOneWrongStepAndNoMore() {
    let arrived = scrollThroughReverser(steps: 30) { $0 < 10 }
    #expect(arrived == [-1] + Array(repeating: 1, count: 9) + [-1] + Array(repeating: 1, count: 19),
            "arrived \(arrived)")
}

// The tap hears each event on the run loop a little after it was posted, so the watch is always
// behind. It must still settle, and keep to the right side once it has.
@Test func aWatchThatHearsLateStillSettles() {
    for lag in 1...3 {
        let arrived = scrollThroughReverser(steps: 40, lag: lag) { _ in true }
        #expect(arrived == Array(repeating: -1, count: lag + 1) + Array(repeating: 1, count: 39 - lag),
                "lag \(lag)")
    }
}

@Test func theHorizontalAxisIsCorrectedOnItsOwn() {
    let arrived = scrollThroughReverser(steps: 20, horizontal: true) { _ in true }
    #expect(arrived == [-1] + Array(repeating: 1, count: 19))
}

@Test func eachAxisFollowsItsOwnReverser() {
    // Scroll Reverser can reverse vertical and horizontal scrolling separately.
    let poster = makePoster()
    let event = poster.scrollEvent(dx: 4, dy: 5, phase: .changed, momentum: nil)!
    let verticalOnly = event.copy()!
    verticalOnly.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -5)
    poster.scrollWatch.observe(verticalOnly)
    #expect(poster.scrollWatch.reversedY)
    #expect(!poster.scrollWatch.reversedX)
    let next = poster.scrollEvent(dx: 4, dy: 5, phase: .changed, momentum: nil)!
    #expect(field(next, .scrollWheelEventPointDeltaAxis1) == -5)
    #expect(field(next, .scrollWheelEventPointDeltaAxis2) == 4)
}
