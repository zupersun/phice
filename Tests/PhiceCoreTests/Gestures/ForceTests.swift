import Testing
@testable import PhiceCore

// Contact as the iPhone 17 measured it: whole steps of 12.139 pt, a 1→2 ramp in the first 50 ms,
// 2 steps for an ordinary finger, 3 for a firm press, 4 and up for a thumb or a hand, 0 on lifting.

@Test func aTouchDownRampingFromOneStepToTwoIsAnOrdinaryTap() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.hold(0.02)
    pad.press(1, to: steps(2))
    pad.hold(0.05)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func restingThenPressingHarderForceClicksOnTheRise() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.hold(0.02)
    pad.press(1, to: steps(2))
    pad.hold(0.38)
    #expect(pad.events.isEmpty)
    pad.press(1, to: steps(3))
    #expect(pad.events == [.forceClick])
    #expect(pad.r.verdicts[1] == .force)
    pad.hold(0.3)
    pad.lift(1)
    #expect(pad.events == [.forceClick])
}

@Test func aQuickFirmPressIsAForceClickAndNotAlsoATap() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.lift(1)
    #expect(pad.events == [.forceClick])
}

@Test func forceClickReArmsOnlyAfterReturningToRest() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.hold(0.2)
    #expect(pad.events == [.forceClick])
    pad.press(1, to: steps(2))
    pad.hold(0.05)
    pad.press(1, to: steps(3))
    #expect(pad.events == [.forceClick, .forceClick])
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

@Test func landingFirmAndHoldingStillIsAForceClick() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(3))
    pad.hold(0.2)
    #expect(pad.events.isEmpty)
    pad.wait(0.08)
    #expect(pad.events == [.forceClick] && pad.r.verdicts[1] == .force)
    pad.hold(0.3)
    pad.lift(1)
    #expect(pad.events == [.forceClick])
}

@Test func aForceClickedTouchPressedEvenHarderKeepsItsBloom() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(3))
    pad.hold(0.3)
    pad.press(1, to: steps(4))
    pad.hold(0.3)
    #expect(pad.events == [.forceClick] && pad.r.verdicts[1] == .force)
}

@Test func aFingerThatFlattensAsItSlidesJustMoves() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.move([1], 60, 0, frames: 12, radius: steps(3))
    pad.hold(0.4)
    pad.lift(1)
    #expect(pad.actions.isEmpty && near(pad.travel.dx, 60))
}

@Test func whenTheMacLooksUpWithAThreeFingerTapAPressIsJustATap() {
    var pad = Pad { $0.lookUpForceClick = false }
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    #expect(pad.r.verdicts[1] == .live)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aSecondFingerDownMeansNoForceClick() {
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

@Test func theQuantumFollowsTheDevice() {
    // A device reporting steps of 10 pt: 30 pt is a firm press there, not an ordinary finger.
    var pad = Pad()
    pad.r.tuning.force.quantum = 10
    pad.land(1, 400, 200, r: 20)
    pad.hold(0.1)
    pad.press(1, to: 30)
    #expect(pad.events == [.forceClick])
}
