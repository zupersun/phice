import AppKit
import CoreGraphics
import PhiceCore
import Testing
@testable import Phice

private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let right = CGRect(x: 1440, y: -200, width: 1920, height: 1080)

@Test func pointsInsideADisplayAreUntouched() {
    #expect(DisplayGeometry.clamp(CGPoint(x: 100, y: 200), to: [main]) == CGPoint(x: 100, y: 200))
    let inside = CGPoint(x: 1500, y: -100)
    #expect(DisplayGeometry.clamp(inside, to: [main, right]) == inside)
}

@Test func pointsOutsideAreBroughtToTheNearestEdge() {
    #expect(DisplayGeometry.clamp(CGPoint(x: -50, y: 450), to: [main]) == CGPoint(x: 0, y: 450))
    #expect(DisplayGeometry.clamp(CGPoint(x: 5000, y: 5000), to: [main]) == CGPoint(x: 1439, y: 899))
    // Below the main display but inside the right one's x-range: the nearer rectangle wins.
    let below = DisplayGeometry.clamp(CGPoint(x: 1000, y: 950), to: [main, right])
    #expect(below == CGPoint(x: 1000, y: 899))
    let belowRight = DisplayGeometry.clamp(CGPoint(x: 1600, y: 950), to: [main, right])
    #expect(belowRight == CGPoint(x: 1600, y: 879))
}

@Test func withoutADisplayListThePointPassesThrough() {
    #expect(DisplayGeometry.clamp(CGPoint(x: -9, y: 9), to: []) == CGPoint(x: -9, y: 9))
}

@Test func withoutAccessibilityThePosterDoesNothing() {
    let pasteboard = NSPasteboard.withUniqueName()
    let poster = QuartzPoster(clipboard: Clipboard(pasteboard: pasteboard,
                                                   store: ClipStore(directory: tempDirectory())))
    poster.trusted = false
    let changes = pasteboard.changeCount
    poster.move(dx: 40, dy: 40, dragging: nil)
    poster.moveTo(x: 10, y: 10, dragging: .left)
    poster.button(.left, down: true, clicks: 1)
    poster.button(.left, down: false, clicks: 1)
    poster.scroll(dx: 0, dy: 10, phase: .changed, momentum: nil)
    poster.shortcut(.missionControl)
    poster.forceClick()
    #expect(poster.perform(.copy) == false)
    #expect(poster.perform(.cut) == false)
    #expect(poster.perform(.shortcut(name: "Anything")) == false)
    poster.paste(itemID: "nothing")
    #expect(poster.posted == 0)
    #expect(pasteboard.changeCount == changes)
}

// The Mac side of "right click is delayed": nothing may sit between the driver's call and the event
// reaching the window server. The sink stands in for it, so nothing is posted to the screen.
@Test func aRightPressAndReleaseArePostedTheMomentTheyArrive() {
    var events: [CGEvent] = []
    let poster = QuartzPoster(
        clipboard: Clipboard(pasteboard: .withUniqueName(),
                             store: ClipStore(directory: tempDirectory())),
        watchScroll: false) { events.append($0) }
    poster.trusted = true

    poster.button(.right, down: true, clicks: 1)
    #expect(events.count == 1)                  // there and then, not queued behind a timer
    poster.button(.right, down: false, clicks: 1)
    #expect(events.map(\.type) == [.rightMouseDown, .rightMouseUp])
    #expect(events.map { $0.getIntegerValueField(.mouseEventButtonNumber) } == [1, 1])
    #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1])
}

@Test func aLeftDoubleClickKeepsItsClickCountOnBothHalves() {
    var events: [CGEvent] = []
    let poster = QuartzPoster(
        clipboard: Clipboard(pasteboard: .withUniqueName(),
                             store: ClipStore(directory: tempDirectory())),
        watchScroll: false) { events.append($0) }
    poster.trusted = true
    poster.button(.left, down: true, clicks: 2)
    poster.button(.left, down: false, clicks: 2)
    #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp])
    #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [2, 2])
}

// The whole Mac side of a scroll: the driver's signs, the poster's correction, a reverser that is
// always on, the watch hearing every event. A swipe and its momentum must go one way, from the
// second event on.
@Test func aWholeSwipeAndItsMomentumGoOneWayThroughAReverser() {
    var arrived: [Int64] = []
    var momentumSteps = 0
    var poster: QuartzPoster!
    poster = QuartzPoster(
        clipboard: Clipboard(pasteboard: .withUniqueName(),
                             store: ClipStore(directory: tempDirectory())),
        watchScroll: false) { event in
        let out = negated(event)
        let dy = out.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        if dy != 0 { arrived.append(dy > 0 ? 1 : -1) }
        if out.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { momentumSteps += 1 }
        poster.scrollWatch.observe(out)
    }
    poster.trusted = true
    let driver = MacDriver(poster: poster, settings: TrackpadSettings(),
                           curves: DefaultCurves.pointerCurves,
                           scrollCurves: DefaultCurves.scrollCurves)

    // A flick: fingers moving down at 2400 pt/s for half a second, lifting at that speed.
    _ = driver.handle(.events([.scroll(dx: 0, dy: 40, phase: .began, t: 0)]), now: 0)
    for i in 1...30 {
        let t = Double(i) / 60
        _ = driver.handle(.events([.scroll(dx: 0, dy: 40, phase: .changed, t: t)]), now: t)
    }
    _ = driver.handle(.events([.scroll(dx: 0, dy: 0, phase: .ended, t: 0.5)]),
                      now: 0.5)
    _ = driver.handle(.events([.scrollEnded(vx: 0, vy: 2400)]), now: 0.5)
    for i in 1...240 { driver.tick(now: 0.5 + Double(i) / 120) }

    #expect(arrived.count > 30)
    #expect(momentumSteps > 0)                  // the coast is part of what is checked
    #expect(Set(arrived.dropFirst()).count == 1, "arrived \(arrived)")
}

// MARK: Which keys a shortcut posts depends on what is in front

private func keyDowns(_ events: [CGEvent]) -> [(code: Int64, flags: CGEventFlags)] {
    events.filter { $0.type == .keyDown }
        .map { ($0.getIntegerValueField(.keyboardEventKeycode), $0.flags.intersection(
            [.maskCommand, .maskControl, .maskShift, .maskAlternate])) }
}

private final class Posted {
    var events: [CGEvent] = []
}

private func poster(front: @escaping () -> String?, into posted: Posted) -> QuartzPoster {
    let poster = QuartzPoster(
        clipboard: Clipboard(pasteboard: .withUniqueName(),
                             store: ClipStore(directory: tempDirectory())),
        watchScroll: false, sink: { posted.events.append($0) }, frontmost: front)
    poster.trusted = true
    return poster
}

// The four-finger spread is Show Desktop (F11); with Apps open it is what dismisses it.
@Test func theSpreadDismissesAppsWhenAppsIsFrontmostAndShowsTheDesktopOtherwise() {
    var front: String? = "com.apple.Safari"
    let posted = Posted()
    let poster = poster(front: { front }, into: posted)

    poster.shortcut(.showDesktop)
    #expect(keyDowns(posted.events).map(\.code) == [103])               // F11
    #expect(posted.events.map(\.type) == [.keyDown, .keyUp])

    for apps in ["com.apple.apps.launcher", "com.apple.launchpad.launcher"] {
        posted.events.removeAll()
        front = apps
        poster.shortcut(.showDesktop)
        #expect(keyDowns(posted.events).map(\.code) == [53], "\(apps)")  // Escape
        #expect(posted.events.map(\.type) == [.keyDown, .keyUp])
    }

    posted.events.removeAll()
    front = nil                                                   // nothing in front: no Apps
    poster.shortcut(.showDesktop)
    #expect(keyDowns(posted.events).map(\.code) == [103])
}

@Test func otherShortcutsAreUnaffectedByAppsBeingOpen() {
    let posted = Posted()
    let poster = poster(front: { "com.apple.apps.launcher" }, into: posted)
    poster.shortcut(.missionControl)
    #expect(keyDowns(posted.events).map(\.code) == [126])
}

@Test func forceClickIsQuickLookInFinderAndLookUpElsewhere() {
    var front: String? = "com.apple.finder"
    let posted = Posted()
    let poster = poster(front: { front }, into: posted)
    poster.forceClick()
    #expect(keyDowns(posted.events).map(\.code) == [49])                // Space
    posted.events.removeAll()
    front = "com.apple.Safari"
    poster.forceClick()
    #expect(keyDowns(posted.events).map(\.code) == [2])                 // ⌃⌘D
    #expect(keyDowns(posted.events).first?.flags == [.maskControl, .maskCommand])
}
