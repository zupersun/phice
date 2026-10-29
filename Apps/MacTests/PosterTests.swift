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
