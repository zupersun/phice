import Testing
@testable import PhiceCore

// The Force Touch trackpad's three levels on a phone that reads contact size in 12.1 pt steps:
// a tap clicks; a press (the contact a step larger at rest) holds the button down; a further step
// while pressed is a deep press, the force click.

private let down = PadEvent.button(.left, down: true, clicks: 1)
private let up = PadEvent.button(.left, down: false, clicks: 1)

@Test func restingThenPressingHarderPutsTheButtonDownUntilTheFingerLifts() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(1))
    pad.hold(0.02)
    pad.press(1, to: steps(2))
    pad.hold(0.38)
    #expect(pad.events.isEmpty)
    pad.press(1, to: steps(3))
    #expect(pad.events == [down])
    #expect(pad.r.verdicts[1] == .pressed)
    pad.hold(0.3)
    pad.lift(1)
    #expect(pad.events == [down, up])
}

@Test func aQuickPressIsOneClickNotAlsoATap() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.lift(1)
    #expect(pad.events == [down, up])
}

@Test func aPressedFingerThatMovesDragsAndAWobbleDoesNotDropIt() {
    // Select text, drag a file: the contact may slip back a step for a moment as the finger slides.
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.move([1], 30, 0)
    pad.press(1, to: steps(2))
    pad.move([1], 10, 0, frames: 4)
    pad.press(1, to: steps(3))
    pad.move([1], 30, 0)
    #expect(pad.actions == [down])
    #expect(near(pad.travel.dx, 70))
    pad.lift(1)
    #expect(pad.actions == [down, up])
}

@Test func easingBackToRestLetsTheButtonUpAndPressingAgainDoubleClicks() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.hold(0.1)
    pad.press(1, to: steps(2))
    pad.hold(0.15)
    #expect(pad.events == [down, up])
    #expect(pad.r.verdicts[1] == .live)
    pad.press(1, to: steps(3))
    #expect(pad.events == [down, up, .button(.left, down: true, clicks: 2)])
}

@Test func landingFirmAndHoldingStillPressesTheButton() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(3))
    pad.hold(0.2)
    #expect(pad.events.isEmpty)
    pad.wait(0.08)
    #expect(pad.events == [down])
    pad.lift(1)
    #expect(pad.events == [down, up])
}

@Test func aFingerThatPointedAndThenRestsCanPress() {
    // Move onto the word, stop, press: as on a MacBook, without lifting first.
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.move([1], 60, 0)
    pad.hold(0.15)
    pad.press(1, to: steps(3))
    #expect(pad.actions == [down])
    #expect(pad.r.verdicts[1] == .pressed)
}

@Test func aFingerFlatteningAsItSetsOffIsNotAPress() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.15)
    pad.move([1], 12, 0, frames: 4, radius: steps(3))
    pad.move([1], 40, 0)
    pad.lift(1)
    #expect(pad.actions.isEmpty)
}

@Test func aFurtherStepWhilePressedIsADeepPress() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.press(1, to: steps(4))
    #expect(pad.events == [down, .forceClick])
    #expect(pad.r.verdicts[1] == .force)
    pad.hold(0.3)
    pad.lift(1)
    #expect(pad.events == [down, .forceClick, up])
}

@Test func aDeepPressNeedsLookUpOnForceClick() {
    var pad = Pad { $0.lookUpForceClick = false }
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.press(1, to: steps(4))
    pad.lift(1)
    #expect(pad.events == [down, up])
}

@Test func aPressedTouchIsNeverTakenForARestingHand() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(3))
    pad.hold(0.3)
    pad.press(1, to: steps(4))
    pad.hold(0.3)
    #expect(pad.events == [down, .forceClick])
    #expect(pad.r.verdicts[1] == .force)
}

@Test func aSecondFingerOnAPressedItemGrabsIt() {
    var pad = Pad()
    pad.land(1, 600, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.hold(0.2)
    pad.land(2, 640, 220)
    pad.move([1, 2], -500, 0)
    pad.lift(1, 2)
    #expect(pad.events == [down, .freeze(true), .drop(.copy)])
}

@Test func theQuantumFollowsTheDevice() {
    // A device reporting steps of 10 pt: 30 pt is a press there, not an ordinary finger.
    var pad = Pad()
    pad.r.tuning.force.quantum = 10
    pad.land(1, 400, 200, r: 20)
    pad.hold(0.1)
    pad.press(1, to: 30)
    #expect(pad.events == [down])
}
