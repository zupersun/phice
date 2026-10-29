import Testing
@testable import PhiceCore

/// Tap, then touch and hold: the left button is down on whatever is under the cursor.
private func holding(_ settings: TrackpadSettings = TrackpadSettings(), pill: Side = .left) -> Pad {
    var pad = Pad(settings, pill: pill)
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 600, 200)
    pad.hold(0.2)
    #expect(pad.events == click() + [press])
    pad.clear()
    return pad
}

@Test func aSecondFingerOnAHeldItemFreezesTheCursorAndGrabsBetweenTheFingers() {
    var pad = holding()
    pad.land(2, 640, 220)
    #expect(pad.events == [.freeze(true)])
    #expect(pad.r.grab == Grab(x: 620, y: 210, inZone: false))
    pad.move([1, 2], -300, 0)
    #expect(pad.r.grab?.inZone == false)
    pad.move([1, 2], -200, 0)
    #expect(pad.r.grab.map { near($0.x, 120) && near($0.y, 210) } == true)
    #expect(pad.r.grab?.inZone == true)
    #expect(near(pad.travel.dx, 0) && near(pad.travel.dy, 0))
    pad.lift(1, 2)
    // The Mac lets the button go itself, where it was pressed: no button-up from here.
    #expect(pad.events == [.freeze(true), .drop(.copy)])
    #expect(pad.r.grab == nil)
}

@Test func liftingOutsideTheZoneCancelsAndLetsGo() {
    var pad = holding()
    pad.land(2, 640, 220)
    pad.move([1, 2], -100, 0)
    pad.lift(1, 2)
    #expect(pad.events == [.freeze(true), .freeze(false), release])
    #expect(pad.r.grab == nil)
}

@Test func leavingTheZoneBeforeLiftingCancels() {
    var pad = holding()
    pad.land(2, 640, 220)
    pad.move([1, 2], -500, 0)
    pad.move([1, 2], 200, 0)
    pad.lift(1, 2)
    #expect(pad.events == [.freeze(true), .freeze(false), release])
}

@Test func theDropCarriesTheChosenAction() {
    var pad = holding()
    pad.r.dropAction = .shortcut(name: "Save to Notes")
    pad.land(2, 640, 220)
    pad.move([1, 2], -500, 0)
    pad.lift(1, 2)
    #expect(pad.events == [.freeze(true), .drop(.shortcut(name: "Save to Notes"))])
}

@Test func theDropZoneIsOnThePillsSide() {
    var pad = holding(pill: .right)
    pad.land(2, 640, 220)
    pad.move([1, 2], -500, 0)
    #expect(pad.r.grab?.inZone == false)
    pad.move([1, 2], 700, 0)
    #expect(pad.r.grab?.inZone == true)
    pad.lift(1, 2)
    #expect(pad.events == [.freeze(true), .drop(.copy)])
}

@Test func theFingersMayLiftOneAtATime() {
    var pad = holding()
    pad.land(2, 640, 220)
    pad.move([1, 2], -500, 0)
    pad.lift(1)
    #expect(pad.events == [.freeze(true)] && pad.r.grab?.inZone == true)
    pad.lift(2)
    #expect(pad.events == [.freeze(true), .drop(.copy)])
}

@Test func aSecondFingerTooSoonAfterTheHeldOneIsNoGrab() {
    var pad = Pad()
    pad.tap()
    pad.wait(0.1)
    pad.land(1, 600, 200)
    pad.move([1], 30, 0, frames: 4)
    pad.land(2, 660, 220)
    pad.move([1, 2], 30, 0, frames: 4)
    pad.lift(1, 2)
    #expect(pad.actions == click() + [press, release])
}

@Test func aSecondFingerWithNothingHeldIsAnOrdinaryTwoFingerGesture() {
    var pad = Pad()
    pad.land(1, 600, 200)
    pad.hold(0.3)
    pad.land(2, 640, 220)
    pad.move([1, 2], 0, 50)
    pad.lift(1, 2)
    #expect(pad.actions.isEmpty && pad.r.grab == nil && near(pad.scrolled.dy, 50))
}

@Test func aCancelledTouchOverTheZoneCancelsRatherThanDrops() {
    var pad = holding()
    pad.land(2, 640, 220)
    pad.move([1, 2], -500, 0)
    pad.cancel(1, 2)
    #expect(pad.events == [.freeze(true), .freeze(false), release])
}
