import SwiftUI

/// Draws the pill and the copy gesture's bead. The bead joins the pill through a liquid neck
/// (`Neck`); a white shape and a black one inset by the border are each the union of pill, bead and
/// neck, and their necks share fillet centres, so the rim keeps its width all the way round.
struct PillCanvas: View, Animatable {
    /// 0...1 while a finger is down on the pill: how far it has swollen (`Press.swell`).
    var press: Double
    let geometry: PillGeometry
    let frame: Swallow.Frame
    /// The white border's opacity at rest: the appearance's border brightness.
    let border: Double
    let filled: Bool
    /// False while the menu or the column has taken the pill's place.
    let drawsPill: Bool

    /// The neck's fillet: the bead joins once its rim is within twice this of the pill's.
    static let fillet: CGFloat = 8

    nonisolated var animatableData: Double {
        get { press }
        set { press = newValue }
    }

    var body: some View {
        Canvas { ctx, _ in
            let pill = pillRect()
            if drawsPill, frame.target > 0 {
                var glow = ctx
                glow.opacity = 0.35 * frame.target
                glow.addFilter(.blur(radius: 12))
                glow.fill(capsule(pill.insetBy(dx: -6, dy: -6)), with: .color(.white))
            }
            let rim = PillGeometry.border, lit = max(frame.target, press)
            let white = shape(pill: pill, beadRadius: frame.beadRadius + rim, fillet: Self.fillet)
            let black = shape(pill: pill.insetBy(dx: rim, dy: rim), beadRadius: frame.beadRadius,
                              fillet: Self.fillet + rim)
            ctx.fill(white, with: .color(.white.opacity(border + (1 - border) * lit)))
            ctx.fill(black, with: .color(.black))
            if frame.docOpacity > 0 { drawDoc(ctx) }
            if drawsPill { drawGlyph(ctx, at: CGPoint(x: pill.midX, y: pill.midY)) }
        }
        .allowsHitTesting(false)
    }

    /// The pill, the bead and the neck between them as one shape.
    private func shape(pill: CGRect, beadRadius r: CGFloat, fillet: CGFloat) -> Path {
        var path = drawsPill ? capsule(pill) : Path()
        guard frame.beadRadius > 0 else { return path }
        let c = frame.bead
        path = path.union(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
        guard drawsPill,
              let neck = Neck.path(pill: pill, side: geometry.side, bead: c, radius: r, fillet: fillet)
        else { return path }
        return path.union(neck)
    }

    private func capsule(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2, style: .circular)
    }

    /// The pill as it is right now: swollen by the press, reaching toward the bead, gulping.
    private func pillRect() -> CGRect {
        let rest = geometry.pill
        let across = rest.width + frame.reach
        let swell = 1 + 0.08 * press
        let width = across * frame.stretch.width * swell
        let height = rest.height * frame.stretch.height * swell
        let centreX = geometry.side == .left ? rest.minX + across / 2 : rest.maxX - across / 2
        return CGRect(x: centreX - width / 2, y: rest.midY - height / 2, width: width, height: height)
    }

    /// The mockup's little document inside the bead, scaled with it.
    private func drawDoc(_ ctx: GraphicsContext) {
        var ctx = ctx
        ctx.opacity = frame.docOpacity
        ctx.translateBy(x: frame.bead.x, y: frame.bead.y)
        let scale = 0.75 * frame.beadRadius / Swallow.beadRadius
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -13, y: -12)
        var page = Path()
        page.addLines([CGPoint(x: 8, y: 4), CGPoint(x: 14, y: 4), CGPoint(x: 18, y: 8),
                       CGPoint(x: 18, y: 20), CGPoint(x: 8, y: 20)])
        page.closeSubpath()
        ctx.fill(page, with: .color(.white))
        var fold = Path()
        fold.addLines([CGPoint(x: 14, y: 4), CGPoint(x: 14, y: 8), CGPoint(x: 18, y: 8)])
        ctx.stroke(fold, with: .color(.black), lineWidth: 1.4)
    }

    private func drawGlyph(_ ctx: GraphicsContext, at centre: CGPoint) {
        var ctx = ctx
        ctx.opacity = PillInk.glyph
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.scaleBy(x: frame.glyphPop * frame.stretch.width, y: frame.glyphPop * frame.stretch.height)
        var glyph = ctx.resolve(Image(systemName: filled ? "clipboard.fill" : "clipboard"))
        glyph.shading = .color(.white)
        let size = glyph.size, height = 20.0
        let width = size.height > 0 ? size.width * height / size.height : height
        ctx.draw(glyph, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    }
}
