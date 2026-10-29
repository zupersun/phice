import Testing
@testable import PhiceCore

@Test func pressingHarderForceClicksOnceAndIsNeverATap() {
    var pad = Pad()
    pad.land(1, 400, 200, r: 20)
    pad.hold(0.06)
    pad.press(1, to: 31)
    #expect(pad.events == [.forceClick])
    #expect(pad.r.verdicts[1] == .force)
    pad.press(1, to: 34)
    pad.lift(1)
    #expect(pad.events == [.forceClick])
}

@Test func forcePressReArmsOnlyAfterEasingBackToRest() {
    var pad = Pad()
    pad.land(1, 400, 200, r: 20)
    pad.hold(0.06)
    pad.press(1, to: 31)
    pad.press(1, to: 26)
    pad.press(1, to: 31)
    #expect(pad.events == [.forceClick])
    pad.press(1, to: 21)
    pad.press(1, to: 31)
    #expect(pad.events == [.forceClick, .forceClick])
}

@Test func whenTheMacLooksUpWithAThreeFingerTapAPressIsJustATap() {
    var pad = Pad { $0.lookUpForceClick = false }
    pad.land(1, 400, 200, r: 20)
    pad.hold(0.06)
    pad.press(1, to: 31)
    #expect(pad.r.verdicts[1] == .live)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aSecondFingerDownMeansNoForceClick() {
    var pad = Pad()
    pad.land([(1, 400, 200), (2, 440, 200)])
    pad.hold(0.06)
    pad.press(1, to: 31)
    #expect(pad.events.isEmpty)
}

@Test func aTouchThatLandsWideAndRelaxesIsAForcePress() {
    var pad = Pad()
    pad.land(1, 400, 200, r: 45)
    pad.hold(0.05)
    #expect(pad.events.isEmpty && pad.r.verdicts[1] == .live)
    pad.press(1, to: 31)
    #expect(pad.events == [.forceClick] && pad.r.verdicts[1] == .force)
    pad.lift(1)
    #expect(pad.events == [.forceClick])
}

@Test func aTouchThatLandsWideAndStaysIsARestingThumbTheOtherFingersIgnore() {
    var pad = Pad()
    pad.land(1, 300, 330, r: 45)
    pad.hold(0.25)
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
    pad.land(1, 300, 330, r: 45)
    pad.hold(0.03)
    pad.tap()
    #expect(pad.events == click())
}

@Test func aQuickTapByAWideFingerStillClicks() {
    var pad = Pad()
    pad.land(1, 400, 200, r: 45)
    pad.hold(0.05)
    pad.lift(1)
    #expect(pad.events == click())
}

@Test func aWideTouchThatMovesIsAFinger() {
    var pad = Pad()
    pad.land(1, 400, 200, r: 45)
    pad.move([1], 60, 0)
    #expect(pad.r.verdicts[1] == .live)
    #expect(pad.travel.dx > 40)
}

@Test func aPalmIsRejectedWhereverItLands() {
    var pad = Pad()
    pad.land(1, 437, 200, r: 70)
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
    pad.press(1, to: 70)
    #expect(pad.r.verdicts[1] == .rejected)
    pad.clear()
    pad.move([1], 30, 0)
    pad.lift(1)
    #expect(pad.events.isEmpty)
}

@Test func aWideStillTouchAtTheEdgeIsTheHandHoldingThePhone() {
    var pad = Pad()
    pad.land(1, 6, 200, r: 30)
    pad.hold(0.25)
    #expect(pad.r.verdicts[1] == .rejected)
    pad.land(2, 6, 300, r: 20)
    #expect(pad.r.verdicts[2] == .live)
    pad.hold(0.05)
    pad.lift(2)
    #expect(pad.events == click())
}

@Test func theSameWidthAwayFromTheEdgeIsAnOrdinaryFinger() {
    var pad = Pad()
    pad.land(1, 400, 200, r: 30)
    pad.hold(0.25)
    #expect(pad.r.verdicts[1] == .live)
}
