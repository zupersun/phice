import Testing
@testable import PhiceCore

// A Force Touch trackpad's click on a phone that reads contact size in 12.1 pt steps: a tap clicks,
// a press (the contact a step larger at rest) holds the button down. Nothing lies above the press:
// a fingertip barely reaches another step, and Look Up is the three-finger tap.

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

@Test func aFurtherStepWhilePressedDoesNothingMore() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.press(1, to: steps(4))
    #expect(pad.events == [down])
    #expect(pad.r.verdicts[1] == .pressed)
    pad.lift(1)
    #expect(pad.events == [down, up])
}

@Test func aPressedTouchIsNeverTakenForARestingHand() {
    var pad = Pad()
    pad.land(1, 400, 200, r: steps(3))
    pad.hold(0.3)
    pad.press(1, to: steps(4))
    pad.hold(0.3)
    #expect(pad.events == [down])
    #expect(pad.r.verdicts[1] == .pressed)
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
    #expect(pad.events == [down, .freeze(true), .drop(.copy), .freeze(false)])
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

@Test func aStrokeRightAfterAPressClickPointsInsteadOfDragging() {
    // A click made by pressing is not a tap, so it arms no tap-to-drag.
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.lift(1)
    pad.wait(0.1)
    pad.land(1, 420, 200)
    pad.move([1], 80, 0)
    pad.lift(1)
    #expect(pad.actions == [down, up])
    #expect(near(pad.travel.dx, 80))
}

@Test func pressingTwiceWithALiftBetweenDoubleClicks() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.lift(1)
    pad.wait(0.1)
    pad.land(1, 402, 200)
    pad.hold(0.2)
    pad.press(1, to: steps(3))
    pad.lift(1)
    #expect(pad.actions == [down, up, .button(.left, down: true, clicks: 2),
                            .button(.left, down: false, clicks: 2)])
}

@Test func aPressPushedAStepHarderStillReArmsWithoutLifting() {
    var pad = Pad()
    pad.land(1, 400, 200)
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.press(1, to: steps(4))
    pad.hold(0.1)
    pad.press(1, to: steps(3))
    pad.hold(0.15)
    #expect(pad.actions == [down])
    pad.press(1, to: steps(2))
    pad.hold(0.15)
    pad.press(1, to: steps(3))
    pad.lift(1)
    #expect(pad.actions == [down, up, .button(.left, down: true, clicks: 2),
                            .button(.left, down: false, clicks: 2)])
}

@Test func everyButtonDownComesBackUpHoweverTheGestureEnds() {
    func balanced(_ events: [PadEvent]) -> Bool {
        events.reduce(0) { held, event in
            if case let .button(.left, isDown, _) = event { held + (isDown ? 1 : -1) } else { held }
        } == 0
    }
    func pressed(_ settings: (inout TrackpadSettings) -> Void = { _ in }) -> Pad {
        var pad = Pad(settings)
        pad.land(1, 400, 200)
        pad.hold(0.1)
        pad.press(1, to: steps(3))
        return pad
    }
    let more: [(UInt16, Double, Double)] = [(2, 450, 200), (3, 490, 210), (4, 530, 200)]
    var cancelled = pressed()
    cancelled.hold(0.1)
    cancelled.cancel(1)
    var vanished = pressed()
    vanished.vanish(1)
    vanished.hold(0.02)
    var crowded = pressed()
    crowded.hold(0.05)
    crowded.land(more)
    crowded.hold(0.1)
    crowded.move([2, 3, 4], 50, 0)
    crowded.lift(2, 3, 4)
    crowded.lift(1)
    var grabbedThenCancelled = pressed()
    grabbedThenCancelled.hold(0.2)
    grabbedThenCancelled.land(more)
    grabbedThenCancelled.hold(0.1)
    grabbedThenCancelled.cancel(1, 2, 3, 4)
    var threeFingerDrag = Pad { $0.threeFingerDrag = true }
    threeFingerDrag.land([(1, 400, 200), (2, 440, 200), (3, 480, 200)])
    threeFingerDrag.move([1, 2, 3], 40, 0)
    threeFingerDrag.land(4, 520, 200)
    threeFingerDrag.hold(0.05)
    threeFingerDrag.cancel(1, 2, 3, 4)
    var locked = Pad { $0.dragLock = true }
    locked.tap()
    locked.wait(0.05)
    locked.land(1, 600, 200)
    locked.hold(0.2)
    locked.lift(1)
    locked.wait(3.2)
    let cases = [("cancelled", cancelled), ("vanished", vanished), ("crowded", crowded),
                 ("grabbed, cancelled", grabbedThenCancelled), ("three-finger drag", threeFingerDrag),
                 ("drag lock", locked)]
    for (name, pad) in cases { #expect(balanced(pad.events), "\(name): \(pad.events)") }
}
