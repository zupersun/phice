import CoreGraphics
import Foundation
import Testing
@testable import PhiceiOS

private let origin = CGPoint(x: 30, y: 200)

@Test func aHoldOpensTheMenuWithNothingHighlighted() {
    var menu = HoldMenu()
    #expect(!menu.isOpen)
    menu.open(at: origin)
    #expect(menu.isOpen)
    #expect(menu.highlight == nil)
}

@Test func theItemUnderTheFingerWaitsUntilItSlides() {
    var menu = HoldMenu()
    menu.open(at: origin)
    menu.move(to: CGPoint(x: 33, y: 204), over: .clipboard)
    #expect(menu.highlight == nil)
    menu.move(to: CGPoint(x: 30, y: 230), over: .clipboard)
    #expect(menu.highlight == .clipboard)
}

@Test func releaseThenTapLeavesTheMenuOpenUntilAnItemIsTapped() {
    var menu = HoldMenu()
    menu.open(at: origin)
    #expect(menu.lift() == nil)
    #expect(menu.isOpen)
    menu.touchDown(over: .settings)
    #expect(menu.highlight == .settings)
    #expect(menu.lift() == .settings)
    #expect(!menu.isOpen)
}

@Test func aTapOutsideTheOpenMenuCollapsesIt() {
    var menu = HoldMenu()
    menu.open(at: origin)
    _ = menu.lift()
    menu.touchDown(over: nil)
    #expect(!menu.isOpen)
}

@Test func holdAndSlideHighlightsWhatTheFingerIsOverAndReleaseSelectsIt() {
    var menu = HoldMenu()
    menu.open(at: origin)
    menu.move(to: CGPoint(x: 30, y: 120), over: .power)
    #expect(menu.highlight == .power)
    menu.move(to: CGPoint(x: 30, y: 280), over: .settings)
    #expect(menu.highlight == .settings)
    #expect(menu.lift() == .settings)
    #expect(!menu.isOpen)
}

@Test func slidingOffTheMenuAndReleasingSelectsNothing() {
    var menu = HoldMenu()
    menu.open(at: origin)
    menu.move(to: CGPoint(x: 30, y: 280), over: .settings)
    menu.move(to: CGPoint(x: 300, y: 280), over: nil)
    #expect(menu.highlight == nil)
    #expect(menu.lift() == nil)
    #expect(menu.isOpen)
}

@Test func theStateButtonKeepsTheMenuOpenToShowTheNewState() {
    var menu = HoldMenu()
    menu.open(at: origin)
    menu.move(to: CGPoint(x: 30, y: 120), over: .power)
    #expect(menu.lift() == .power)
    #expect(menu.isOpen)
    #expect(menu.highlight == nil)
    menu.touchDown(over: .power)
    #expect(menu.lift() == .power)
    #expect(menu.isOpen)
}

/// One motion from contact: the swell's out-and-back is the hold, and the menu opens as it ends.
@Test func aPressBecomesAHoldAfterTwoTenthsOfASecond() {
    var press = Press(at: origin, t: 10)
    #expect(press.tick(10.19) == nil)
    #expect(press.move(to: CGPoint(x: 36, y: 204), t: 10.1) == nil)
    #expect(press.tick(10.2) == .hold)
    #expect(press.tick(10.5) == nil)
    #expect(press.move(to: CGPoint(x: 90, y: 200), t: 10.6) == nil)
}

@Test func aPressThatMovesFirstIsADragAndNeverAHold() {
    var press = Press(at: origin, t: 10)
    #expect(press.move(to: CGPoint(x: 45, y: 200), t: 10.1) == .drag)
    #expect(press.tick(10.5) == nil)
    #expect(press.kind == .drag)
}

@Test func draggingOutMovesTheCursorOnlyOverThePadAndPastesOnLift() {
    var drag = DragOut(itemID: "a", at: CGPoint(x: 30, y: 200))
    #expect(drag.move(to: CGPoint(x: 40, y: 200), overPad: false, t: 1) == nil)
    #expect(drag.move(to: CGPoint(x: 70, y: 190), overPad: true, t: 2)
        == .move(dx: 30, dy: -10, t: 2))
    #expect(drag.move(to: CGPoint(x: 75, y: 195), overPad: true, t: 3)
        == .move(dx: 5, dy: 5, t: 3))
    #expect(drag.lift(overPad: true) == .paste(itemID: "a"))
    #expect(drag.lift(overPad: false) == nil)
}

@Test func theSwellStartsOnContactPeaksHalfwayAndIsBackAsTheMenuOpens() {
    #expect(Press.swell(0) == 0)
    #expect(Press.swell(1.0 / 60) > 0.2)
    #expect(abs(Press.swell(Press.holdDelay / 2) - 1) < 1e-9)
    #expect(abs(Press.swell(Press.holdDelay)) < 1e-9)
    #expect(Press.swell(Press.holdDelay + 0.05) == 0)
    #expect(Press.swell(-0.01) == 0)
    let rising = stride(from: 0.0, to: Press.holdDelay / 2, by: 0.01).map(Press.swell)
    #expect(rising == rising.sorted())
}

/// The hold sleeps, then checks how long the finger has been down. Both must read one monotonic
/// clock: against the wall clock an NTP slew could leave the check short and the menu shut.
@MainActor @Test func pillTimeIsTheMonotonicClockItsTimersSleepOn() async throws {
    #expect(abs(PillLayer.now - ProcessInfo.processInfo.systemUptime) < 1)
    let before = PillLayer.now
    try await Task.sleep(for: .seconds(Press.holdDelay), clock: .suspending)
    var press = Press(at: .zero, t: before)
    #expect(press.tick(PillLayer.now) == .hold)
}
