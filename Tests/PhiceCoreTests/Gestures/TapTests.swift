import Testing
@testable import PhiceCore

@Test func tapClicksTheMomentItLifts() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.05)
    #expect(pad.events.isEmpty)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aMovingFingerMovesTheCursorByAllItTravelledAndNeverClicks() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.move([1], 30, -12)
    pad.lift(1)
    #expect(pad.actions.isEmpty)
    #expect(near(pad.travel.dx, 30) && near(pad.travel.dy, -12))
}

@Test func theTravelInsideTheSlopArrivesAsTheSamplesThatMadeIt() {
    // Each with its own time, after a still move dating where it started, so the Mac's
    // acceleration sees how fast the finger went rather than one lump.
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.move([1], 12, 0, frames: 3)
    let t = (1 ... 4).map { Double($0) / 120 }
    #expect(pad.events == [.move(dx: 0, dy: 0, t: t[0]), .move(dx: 4, dy: 0, t: t[1]),
                           .move(dx: 4, dy: 0, t: t[2]), .move(dx: 4, dy: 0, t: t[3])])
}

@Test func aLongCreepUnderTheSlopStillFitsInOneFrame() throws {
    // A finger creeping 6 pt over 150 s, then setting off: what it held back must not overflow
    // the one message it goes out in, nor lose any of the way it went.
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.move([1], 6, 0, frames: 150 * 120)
    pad.clear()
    pad.move([1], 10, 0, frames: 1)
    let frame = try FrameCodec.encode(PhoneToMac.events(pad.events))
    #expect(frame.count - 4 <= FrameCodec.maxFrame)
    #expect(frame.count < 16_384)
    #expect(near(pad.travel.dx, 16))
}

@Test func jitterInsideTheSlopIsStillATapAndMovesNothing() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.move([1], 3, 2, frames: 3)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aSlowTouchIsNotATap() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.5)
    pad.lift(1)
    #expect(pad.events.isEmpty)
}

@Test func quickTapsInOnePlaceCountUpToDoubleAndTripleClicks() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.1)
    pad.tap()
    pad.wait(0.1)
    pad.tap()
    #expect(pad.events == click(.left, 1) + click(.left, 2) + click(.left, 3))
}

@Test func tapsTooSlowOrTooFarApartAreSeparateClicks() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.6)
    pad.tap()
    pad.wait(0.1)
    pad.tap(700, 100)
    #expect(pad.events == click() + click() + click())
}

@Test func aCancelledTouchIsNeverATap() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.cancel(1)
    #expect(pad.events.isEmpty)
}

@Test func aTouchThatVanishesWithoutLiftingIsCancelled() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.vanish(1)
    pad.hold(0.02)
    #expect(pad.events.isEmpty)
    pad.wait(0.6)
    pad.land(2, 400, 200)
    pad.move([2], 30, 0)
    pad.lift(2)
    #expect(pad.actions.isEmpty)
    #expect(near(pad.travel.dx, 30))
}

@Test func tapThenHoldGrabsAndDragsUntilLifted() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 400, 200)
    pad.hold(0.2)
    #expect(pad.events == click() + [press])
    pad.move([1], 50, 0)
    pad.lift(1)
    #expect(pad.actions == click() + [press, release])
    #expect(near(pad.travel.dx, 50))
}

@Test func tapThenMoveDragsAtOnce() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 400, 200)
    pad.move([1], 40, 0, frames: 4)
    pad.lift(1)
    #expect(pad.actions == click() + [press, release])
    #expect(near(pad.travel.dx, 40))
}

@Test func aTouchLandingWellAfterAClickMovesTheCursorRatherThanDragging() {
    // Click a button, then put the finger down to move on: that is pointing, not a drag.
    var pad = Pad()
    pad.tap()
    pad.wait(0.3)
    pad.land(1, 400, 200)
    pad.hold(0.2)
    pad.move([1], 40, 0)
    pad.lift(1)
    #expect(pad.actions == click())
    #expect(near(pad.travel.dx, 40))
}

@Test func aSecondTapWithinTheDoubleClickIntervalStillCountsTwo() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.3)
    pad.tap()
    #expect(pad.events == click(.left, 1) + click(.left, 2))
}

@Test func aTouchAfterTheDoubleTapIntervalJustMoves() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.6)
    pad.land(1, 400, 200)
    pad.move([1], 40, 0)
    pad.lift(1)
    #expect(pad.actions == click())
}

@Test func dragLockKeepsHoldingAcrossLiftsUntilTheNextTap() {
    var pad = Pad { $0.dragLock = true }
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 400, 200)
    pad.move([1], 40, 0)
    pad.lift(1)
    pad.wait(1)
    pad.land(2, 300, 200)
    pad.move([2], 40, 0)
    pad.lift(2)
    #expect(pad.actions == click() + [press])
    #expect(near(pad.travel.dx, 80))
    pad.wait(0.3)
    pad.tap()
    #expect(pad.actions == click() + [press, release])
}

@Test func dragLockLetsGoOnItsOwnEventually() {
    var pad = Pad { $0.dragLock = true }
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 400, 200)
    pad.move([1], 40, 0)
    pad.lift(1)
    pad.wait(1)
    #expect(pad.actions == click() + [press])
    pad.wait(5)
    #expect(pad.actions == click() + [press, release])
}

@Test func withoutDragLockLiftingEndsTheDrag() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 400, 200)
    pad.move([1], 40, 0)
    pad.lift(1)
    pad.wait(0.1)
    pad.land(2, 400, 200)
    pad.move([2], 40, 0)
    pad.lift(2)
    #expect(pad.actions == click() + [press, release])
}

@Test func tapsClickEvenWhenTheMacHasTapToClickOffBecauseThePadHasNoButton() {
    var pad = Pad { $0.tapToClick = false; $0.smartZoom = false }
    pad.tap()
    pad.wait(0.6)
    pad.tap(fingers: 2)
    #expect(pad.events == click() + click(.right))
}

@Test func twoFingerTapRightClicksTheMomentItLiftsEvenWithSmartZoomOn() {
    var pad = Pad()
    pad.tap(fingers: 2)
    #expect(pad.events == click(.right))

    var noZoom = Pad { $0.smartZoom = false }
    noZoom.tap(fingers: 2)
    #expect(noZoom.events == click(.right))
}

@Test func twoFingersLandingAndLiftingRaggedlyAreStillOneSecondaryClick() {
    var pad = Pad { $0.smartZoom = false }
    pad.land(1, 400, 200)
    pad.land(2, 440, 205)
    pad.hold(0.03)
    pad.lift(1)
    pad.lift(2)
    #expect(pad.events == click(.right))
}

@Test func cornerTapsAreSecondaryClicksWhenTheMacSaysSo() {
    var right = Pad { $0.secondaryClick = .bottomRight }
    right.tap(850, 390)
    right.wait(0.6)
    right.tap(30, 390)
    right.wait(0.6)
    right.tap(fingers: 2)
    right.wait(0.6)
    #expect(right.events == click(.right) + click())

    var left = Pad { $0.secondaryClick = .bottomLeft }
    left.tap(30, 390)
    left.wait(0.6)
    left.tap(850, 390)
    #expect(left.events == click(.right) + click())
}

@Test func twoFingerDoubleTapSmartZoomsInThenBack() {
    var pad = Pad()
    pad.tap(fingers: 2)
    pad.wait(0.1)
    pad.tap(fingers: 2)
    #expect(pad.events == click(.right) + [.shortcut(.zoomIn)])
    pad.wait(0.6)
    pad.tap(fingers: 2)
    pad.wait(0.1)
    pad.tap(fingers: 2)
    let again = click(.right) + [.shortcut(.zoomReset)]
    #expect(pad.events == click(.right) + [.shortcut(.zoomIn)] + again)
}

@Test func withoutSmartZoomATwoFingerDoubleTapIsTwoSecondaryClicks() {
    var pad = Pad { $0.smartZoom = false }
    pad.tap(fingers: 2)
    pad.wait(0.1)
    pad.tap(fingers: 2)
    #expect(pad.events == click(.right) + click(.right))
}

@Test func threeFingerTapLooksUp() {
    // The pad has no press deeper than a click, so Look Up is where the Mac's own option puts it.
    var pad = Pad()
    pad.tap(fingers: 3)
    #expect(pad.events == [.forceClick])
}
