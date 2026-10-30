import Testing
@testable import PhiceCore

// Contact as the iPhone 17 measured it: whole steps of 12.139 pt, a 1→2 ramp in the first 50 ms,
// 2 steps for an ordinary finger, 3 for a firm press, 4 and up for a thumb or a hand, 0 on lifting.
// Pressing is in PressTests; this is how contact size is judged.

@Test func aTouchDownRampingFromOneStepToTwoIsAnOrdinaryTap() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.hold(0.02)
    pad.press(1, to: steps(2))
    pad.hold(0.05)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aSlowGlideThatFlattensIsNotAPress() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.move([1], 60, 0, frames: 120, radius: steps(3))
    pad.lift(1)
    #expect(pad.actions.isEmpty)
}

@Test func risingOnlyToTwoStepsIsNotAPress() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.hold(0.1)
    pad.press(1, to: steps(2))
    pad.hold(0.5)
    #expect(pad.events.isEmpty)
}

@Test func landingFirmAndLiftingQuicklyIsAnOrdinaryTap() {
    // Lifting reports radius 0, which must not read as anything.
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(3))
    pad.hold(0.12)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aFingerThatFlattensAsItSlidesJustMoves() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.move([1], 60, 0, frames: 12, radius: steps(3))
    pad.hold(0.4)
    pad.lift(1)
    #expect(pad.actions.isEmpty && near(pad.travel.dx, 60))
}

@Test func aSecondFingerDownMeansNoPress() {
    var pad = Pad()
    pad.land([(1, 400, 200), (2, 440, 200)])
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.hold(0.3)
    #expect(pad.events.isEmpty)
}

@Test func aFirmFingerAtThreeStepsIsNeverRejected() {
    var pad = Pad()
    pad.land([(1, 400, 200), (2, 440, 200)], r: steps(3))
    pad.hold(0.5)
    #expect(pad.r.verdicts == [1: .live, 2: .live])
}

@Test func aTouchLandingAtFourStepsAndStayingIsARestingThumbTheOtherFingersIgnore() {
    var pad = Pad()
    pad.land(1, 300, 330, r: steps(4))
    pad.hold(0.1)
    #expect(pad.r.verdicts[1] == .live)
    pad.hold(0.1)
    #expect(pad.r.verdicts[1] == .rejected)
    pad.tap()
    #expect(pad.events == click())
    pad.wait(0.6)
    pad.land(2, 500, 150)
    pad.move([2], 40, 0)
    pad.lift(2)
    #expect(pad.scrollPhases.isEmpty && near(pad.travel.dx, 40))
    pad.lift(1)
    #expect(pad.actions == click())
}

@Test func aThumbStillBeingJudgedDoesNotTurnATapIntoASecondaryClick() {
    var pad = Pad()
    pad.land(1, 300, 330, r: steps(4))
    pad.hold(0.03)
    pad.tap()
    #expect(pad.events == click())
}

@Test func aQuickTapByAWideFingerStillClicks() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(4))
    pad.hold(0.05)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aWideTouchThatMovesIsAFinger() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(4))
    pad.move([1], 60, 0)
    #expect(pad.r.verdicts[1] == .live)
    #expect(pad.travel.dx > 40)
}

@Test func aFlatThumbRollingDownIsRejectedWithoutAForceClick() {
    var pad = Pad()
    pad.land(1, 300, 340)
    pad.hold(0.1)
    pad.press(1, to: steps(4))
    pad.hold(0.05)
    pad.press(1, to: steps(5))
    #expect(pad.r.verdicts[1] == .rejected)
    pad.press(1, to: steps(6))
    pad.tap(500, 150)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aFingerSpreadingToFourStepsAndStayingStillIsRejected() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(4))
    pad.hold(0.1)
    #expect(pad.r.verdicts[1] == .live)
    pad.hold(0.07)
    #expect(pad.r.verdicts[1] == .rejected)
    #expect(pad.events.isEmpty)
}

@Test func aPalmIsRejectedWhereverItLands() {
    var pad = Pad()
    pad.land(1, 437, 200, r: steps(6))
    #expect(pad.r.verdicts[1] == .rejected)
    pad.tap(600, 100)
    pad.move([1], 50, 50)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aFingerThatSpreadsIntoAPalmDropsOutOfTheGesture() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.move([1], 30, 0)
    pad.press(1, to: steps(5))
    #expect(pad.r.verdicts[1] == .rejected)
    pad.clear()
    pad.move([1], 30, 0)
    pad.lift(1)
    #expect(pad.events.isEmpty)
}
