import PhiceCore
import SwiftUI

/// The liquid join between the pill and the bead, as geometry: the region between the pill's flat
/// side and the bead closed by two arcs of radius `fillet` tangent to both. It pinches into being
/// when the gap closes to twice the fillet and fattens as the bead nears, as a metaball's neck does.
/// The mockup made it by blurring and thresholding, which renders soft and stair-stepped on device
/// because the blur is computed at reduced resolution.
enum Neck {
    static func path(pill: CGRect, side: Side, bead: CGPoint, radius r: CGFloat,
                     fillet f: CGFloat) -> Path? {
        // Work as if the pill were on the left, its flat side at `edge`, then mirror back.
        let edge = side == .left ? pill.maxX : pill.minX
        let x = side == .left ? bead.x : 2 * edge - bead.x
        let gap = x - r - edge
        guard gap < 2 * f, gap > -r else { return nil }
        let centreX = edge + f, dx = x - centreX
        let dy = ((r + f) * (r + f) - dx * dx).squareRoot()
        let straight = pill.minY + pill.width / 2 ... pill.maxY - pill.width / 2
        guard straight.contains(bead.y - dy), straight.contains(bead.y + dy) else { return nil }

        let tangent = atan2(dy, dx)
        var path = Path()
        path.move(to: CGPoint(x: edge, y: bead.y - dy))
        arc(&path, centre: CGPoint(x: centreX, y: bead.y - dy), radius: f, from: .pi, to: tangent)
        path.addLine(to: CGPoint(x: x, y: bead.y))
        arc(&path, centre: CGPoint(x: centreX, y: bead.y + dy), radius: f, from: -tangent, to: -.pi)
        path.closeSubpath()
        guard side == .right else { return path }
        return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * edge, ty: 0))
    }

    private static func arc(_ path: inout Path, centre: CGPoint, radius: CGFloat,
                            from: CGFloat, to: CGFloat) {
        let steps = 12
        for i in 0 ... steps {
            let a = from + (to - from) * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a)))
        }
    }
}
