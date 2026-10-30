import CoreGraphics
import PhiceCore

/// Where the pill and everything that grows out of it sit, in screen points. Landscape: the pill is
/// the idle Dynamic Island turned on its side, centred on `side`'s edge and inset from it as the
/// island is from its own edge. Rects are laid out from the left edge and mirrored for the right.
struct PillGeometry: Equatable {
    /// The idle island, long side first. Every iPhone with an island so far uses this size.
    static let island = CGSize(width: 126, height: 37.33)
    /// The island's distance from its edge, by portrait screen width. The 402 and 440 pt screens
    /// (16 Pro onward) gained 3 pt of top safe area over 393 and 430 with the same island, so it
    /// sits 3 pt lower; estimated from that, to confirm on a device.
    static let insets: [CGFloat: CGFloat] = [393: 11.33, 430: 11.33, 402: 14.33, 440: 14.33]
    static let fallbackInset: CGFloat = 11.33
    static let border: CGFloat = 2
    /// Hold-menu items sit this far apart along the edge, clipboard at the pill's centre.
    static let itemSpacing: CGFloat = 60
    /// The menu is the pill grown along the edge: its thickness, long enough for three items.
    static let menuLength: CGFloat = 200
    // The clipboard column, from the approved mockup at 852 pt wide.
    static let columnInset = CGSize(width: 22, height: 30)
    static let columnPadding: CGFloat = 17
    static let headerHeight: CGFloat = 23
    static let rowHeight: CGFloat = 42
    static let rowGap: CGFloat = 11

    let screen: CGSize
    let side: Side

    var inset: CGFloat { Self.insets[min(screen.width, screen.height)] ?? Self.fallbackInset }

    var pill: CGRect {
        let size = Self.island
        return mirrored(CGRect(x: inset, y: (screen.height - size.width) / 2,
                               width: size.height, height: size.width))
    }

    var menu: CGRect {
        mirrored(CGRect(x: inset, y: (screen.height - Self.menuLength) / 2,
                        width: Self.island.height, height: Self.menuLength))
    }

    /// What the pad gives up on the pill's side while the column is open: about a third.
    var columnWidth: CGFloat { (screen.width * 0.36).rounded() }

    var column: CGRect {
        let inset = Self.columnInset
        return mirrored(CGRect(x: inset.width, y: inset.height, width: (screen.width * 0.30).rounded(),
                               height: screen.height - 2 * inset.height))
    }

    /// How many clipboard rows fit in the column.
    var rowCount: Int {
        let room = column.height - 2 * Self.columnPadding - Self.headerHeight + Self.rowGap
        return max(0, Int(room / (Self.rowHeight + Self.rowGap)))
    }

    func row(_ index: Int) -> CGRect {
        let top = column.minY + Self.columnPadding + Self.headerHeight
            + CGFloat(index) * (Self.rowHeight + Self.rowGap)
        return CGRect(x: column.minX + Self.columnPadding, y: top,
                      width: column.width - 2 * Self.columnPadding, height: Self.rowHeight)
    }

    func row(at point: CGPoint) -> Int? {
        (0 ..< rowCount).first { row($0).insetBy(dx: 0, dy: -Self.rowGap / 2).contains(point) }
    }

    /// How far a point is from the pill's edge of the screen.
    func distanceFromEdge(_ point: CGPoint) -> CGFloat {
        side == .left ? point.x : screen.width - point.x
    }

    /// A point in the pad's coordinates on screen: the pad starts after the column on the pill's side.
    func onScreen(_ grab: Grab, columnWidth: CGFloat) -> CGPoint {
        CGPoint(x: side == .left ? grab.x + columnWidth : grab.x, y: grab.y)
    }

    /// Whether a finger dragging something out of the pill or the column is over the pad.
    func overPad(_ point: CGPoint, columnWidth: CGFloat) -> Bool {
        columnWidth > 0 ? distanceFromEdge(point) > columnWidth
            : !pill.insetBy(dx: -8, dy: -8).contains(point)
    }

    func centre(of item: MenuItem) -> CGPoint {
        CGPoint(x: menu.midX, y: menu.midY + CGFloat(item.rawValue - 1) * Self.itemSpacing)
    }

    /// The menu item under a finger, or nil when it is off the menu.
    func item(at point: CGPoint) -> MenuItem? {
        let along = point.y - menu.midY
        guard distanceFromEdge(point) < inset + menu.width + 24, abs(along) < menu.height / 2 + 12
        else { return nil }
        let index = Int((along / Self.itemSpacing + 1).rounded())
        return MenuItem(rawValue: min(max(index, 0), MenuItem.allCases.count - 1))
    }

    private func mirrored(_ rect: CGRect) -> CGRect {
        guard side == .right else { return rect }
        return CGRect(x: screen.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

/// How bright the pill's white is. The pad holds the screen at minimum brightness, so nothing here
/// goes faint: a pill dimmed to 16% white there was invisible on a real iPhone.
enum PillInk {
    static let glyph = 1.0

    /// While the connecting sweep runs the border is held at half, so the blue reads over it
    /// without the outline disappearing.
    static func border(_ brightness: Double, connected: Bool) -> Double {
        connected ? brightness : min(brightness, 0.5)
    }
}
