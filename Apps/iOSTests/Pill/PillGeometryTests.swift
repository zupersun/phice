import CoreGraphics
import PhiceCore
import Testing
@testable import PhiceiOS

/// iPhone 15 Pro and 16: 393 × 852 portrait.
private let small = CGSize(width: 852, height: 393)
/// iPhone 16 Pro Max onward: 440 × 956 portrait.
private let large = CGSize(width: 956, height: 440)

@Test func thePillIsTheIdleIslandOnItsSideInsetFromTheLeftEdge() {
    let pill = PillGeometry(screen: small, side: .left).pill
    #expect(pill.width == 37.33)
    #expect(pill.height == 126)
    #expect(pill.minX == 11.33)
    #expect(pill.midY == 196.5)
}

@Test func onTheRightTheSamePillIsMirrored() {
    let pill = PillGeometry(screen: small, side: .right).pill
    #expect(abs(pill.maxX - (852 - 11.33)) < 0.001)
    #expect(pill.width == 37.33)
    #expect(pill.midY == 196.5)
}

@Test func theInsetFollowsTheScreenSizeWithAFallback() {
    #expect(PillGeometry(screen: large, side: .left).inset == 14.33)
    #expect(PillGeometry(screen: CGSize(width: 402, height: 874), side: .left).inset == 14.33)
    let unknown = PillGeometry(screen: CGSize(width: 900, height: 420), side: .left)
    #expect(unknown.inset == 11.33)
    #expect(unknown.pill.size == CGSize(width: 37.33, height: 126))
}

@Test func aGrabMapsFromPadPointsToTheScreenPastTheColumn() {
    let grab = Grab(x: 100, y: 50, inZone: false)
    #expect(PillGeometry(screen: small, side: .left).onScreen(grab, columnWidth: 300)
        == CGPoint(x: 400, y: 50))
    #expect(PillGeometry(screen: small, side: .right).onScreen(grab, columnWidth: 300)
        == CGPoint(x: 100, y: 50))
    #expect(PillGeometry(screen: small, side: .left).onScreen(grab, columnWidth: 0)
        == CGPoint(x: 100, y: 50))
}

@Test func menuItemsStackAlongTheEdgeWithClipboardAtThePill() {
    for side in [Side.left, .right] {
        let g = PillGeometry(screen: small, side: side)
        let centre = CGPoint(x: g.pill.midX, y: g.pill.midY)
        #expect(g.item(at: centre) == .clipboard)
        #expect(g.item(at: CGPoint(x: centre.x, y: centre.y - 80)) == .power)
        #expect(g.item(at: CGPoint(x: centre.x, y: centre.y + 80)) == .settings)
        #expect(g.item(at: g.centre(of: .power)) == .power)
        #expect(g.item(at: CGPoint(x: small.width / 2, y: centre.y)) == nil)
        #expect(g.item(at: CGPoint(x: centre.x, y: 10)) == nil)
    }
}

@Test func theColumnTakesAboutAThirdOnThePillsSide() {
    let left = PillGeometry(screen: small, side: .left)
    #expect(left.columnWidth == 307)
    #expect(left.column.minX == 22)
    #expect(left.column.maxX < left.columnWidth)
    let right = PillGeometry(screen: small, side: .right)
    #expect(right.column.maxX == 830)
    #expect(right.rowCount >= 4)
    #expect(right.row(at: CGPoint(x: right.row(0).midX, y: right.row(1).midY)) == 1)
}

@Test func dragsAreOverThePadOnceTheyLeaveThePillOrTheColumn() {
    let g = PillGeometry(screen: small, side: .left)
    #expect(!g.overPad(CGPoint(x: g.pill.midX, y: g.pill.midY), columnWidth: 0))
    #expect(g.overPad(CGPoint(x: 200, y: 200), columnWidth: 0))
    #expect(g.overPad(CGPoint(x: 20, y: 20), columnWidth: 0))
    #expect(!g.overPad(CGPoint(x: 200, y: 200), columnWidth: 307))
    #expect(g.overPad(CGPoint(x: 400, y: 200), columnWidth: 307))
}

@Test func theBorderDimsThirtySecondsAfterTheLastTouch() {
    #expect(!Dimming.isDimmed(now: 129.9, lastTouch: 100))
    #expect(Dimming.isDimmed(now: 130, lastTouch: 100))
    #expect(!Dimming.isDimmed(now: 130, lastTouch: 130))
}
