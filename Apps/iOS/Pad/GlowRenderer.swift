import PhiceCore
import QuartzCore

extension GlowColor {
    func cgColor(alpha: Double) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: min(max(alpha, 0), 1))
    }
}

/// The light under each finger. Core Animation layers moved and resized once a frame with implicit
/// animations off, so 120 fps costs a few property writes and no SwiftUI diffing.
@MainActor final class GlowRenderer {
    let layer = CALayer()
    private var glows: [UInt16: Glow] = [:]
    private var fading: [(layer: CALayer, until: Double)] = []
    private var style: Appearance?
    private static let fadeTime = 0.15

    func update(_ touches: [UInt16: Touch], verdicts: [UInt16: TouchVerdict], appearance: Appearance,
                now: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if appearance != style {
            style = appearance
            for glow in glows.values { glow.style(appearance) }
        }
        fading.removeAll { item in
            guard now >= item.until else { return false }
            item.layer.removeFromSuperlayer()
            return true
        }
        let touches = appearance.glow ? touches : [:]
        for (id, glow) in glows where touches[id] == nil {
            glows[id] = nil
            fade(glow.root, now: now)
        }
        for (id, touch) in touches {
            glows[id, default: Glow(in: layer, appearance)]
                .draw(touch, verdicts[id] ?? .live, now: now)
        }
    }

    private func fade(_ root: CALayer, now: Double) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = root.opacity
        fade.toValue = 0
        fade.duration = Self.fadeTime
        root.opacity = 0
        root.add(fade, forKey: "fade")
        fading.append((root, now + Self.fadeTime))
    }
}

/// One finger: a soft light, the bloom of a force press over it, and the ring of a rejected touch.
@MainActor private struct Glow {
    let root = CALayer()
    let light = CAGradientLayer()
    let bloom = CAGradientLayer()
    let ring = CAShapeLayer()
    var state = GlowState()

    init(in parent: CALayer, _ appearance: Appearance) {
        for gradient in [light, bloom] {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.locations = [0, 0.38, 0.72]
        }
        ring.fillColor = nil
        ring.lineWidth = 1.5
        // A zero-size root puts its own origin at the finger; every sublayer is centred there.
        for sublayer in [light, bloom, ring] { root.addSublayer(sublayer) }
        parent.addSublayer(root)
        style(appearance)
    }

    func style(_ appearance: Appearance) {
        let peak = 0.95 * appearance.glowIntensity
        let colors = [peak, peak * 0.45, 0].map { appearance.glowColor.cgColor(alpha: $0) }
        light.colors = colors
        bloom.colors = colors
        ring.strokeColor = appearance.glowColor.cgColor(alpha: 0.22 * appearance.glowIntensity)
    }

    mutating func draw(_ touch: Touch, _ verdict: TouchVerdict, now: Double) {
        let shape = state.step(contact: touch.radius, verdict: verdict, now: now)
        root.position = CGPoint(x: touch.x, y: touch.y)
        light.isHidden = shape.hollow
        bloom.isHidden = shape.hollow || shape.bloomAlpha == 0
        ring.isHidden = !shape.hollow
        light.bounds.size = CGSize(width: 2 * shape.light, height: 2 * shape.light)
        bloom.bounds.size = CGSize(width: 2 * shape.bloom, height: 2 * shape.bloom)
        bloom.opacity = Float(shape.bloomAlpha)
        // The ring sits where a live light would fade out, so a rejected touch reads the same size.
        if shape.hollow {
            let r = 0.72 * shape.light
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r),
                               transform: nil)
        }
    }
}
