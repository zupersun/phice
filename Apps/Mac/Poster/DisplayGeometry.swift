import CoreGraphics

enum DisplayGeometry {
    /// A point inside any display stays; one outside moves to the nearest point of the nearest
    /// display, so an L-shaped arrangement cannot trap or lose the cursor.
    static func clamp(_ p: CGPoint, to displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty, !displays.contains(where: { $0.contains(p) }) else { return p }
        return displays
            .map {
                CGPoint(x: min(max(p.x, $0.minX), $0.maxX - 1),
                        y: min(max(p.y, $0.minY), $0.maxY - 1))
            }
            .min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }!
    }
}
