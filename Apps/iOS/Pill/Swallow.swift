import CoreGraphics
import Foundation

/// SwiftUI's `Spring(duration:bounce:)` written out, as the approved mockup does: mass 1, stiffness
/// (2π / duration)², damping ratio 1 − bounce. Written out because the swallow needs its impulse
/// response (`kick`) as well as its step, and both as plain functions of time.
struct SpringCurve: Equatable {
    var duration: Double
    var bounce: Double

    /// From 0 to 1, overshooting by the bounce.
    func step(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / duration, z = 1 - bounce
        if z >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// Kicked from rest: a decaying wobble around 0.
    func kick(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / duration, z = 1 - bounce, wd = w * (1 - z * z).squareRoot()
        return exp(-z * w * t) * sin(wd * t)
    }
}

/// The copy gesture's look as a pure function of time, ported from the approved mockup's script:
/// the bead appears, the pill lights and reaches toward it, and on release the pill either
/// swallows it or lets it shrink away.
struct Swallow: Equatable {
    static let appear = SpringCurve(duration: 0.35, bounce: 0.45)
    static let gulp = SpringCurve(duration: 0.55, bounce: 0.5)
    static let pop = SpringCurve(duration: 0.35, bounce: 0.5)
    static let relax = SpringCurve(duration: 0.4, bounce: 0.4)
    static let pullIn = 0.3
    static let shrink = 0.25
    static let beadRadius = 16.0
    static let maxReach = 16.0
    /// Gulp amplitude: the kick peaks near 0.47, so this makes the pill about a third wider.
    static let gulpDepth = 0.7

    struct Frame: Equatable {
        var bead = CGPoint.zero
        var beadRadius = 0.0
        var beadOpacity = 1.0
        /// The small document drawn inside the bead.
        var docOpacity = 0.0
        /// How far the pill has grown toward the bead, in points.
        var reach = 0.0
        /// The gulp's squash and stretch, as scale factors across and along the edge.
        var stretch = CGSize(width: 1, height: 1)
        var glyphPop = 1.0
        /// How lit the pill is as the drop target, 0...1.
        var target = 0.0
    }

    private(set) var began: Double?
    private(set) var ended: Double?
    private(set) var swallowed = false
    private var released = CGPoint.zero
    private var releasedDistance = Double.infinity

    /// When the bead joins the pill: the success haptic, the gulp and the glyph's pop.
    var merge: Double? { swallowed ? ended.map { $0 + Self.pullIn } : nil }

    mutating func begin(at t: Double) {
        self = Swallow()
        began = t
    }

    /// The grab ended with the bead at `bead`, `distance` from the pill's edge.
    mutating func end(at t: Double, bead: CGPoint, distance: Double, swallowed: Bool) {
        guard began != nil, ended == nil else { return }
        ended = t
        released = bead
        releasedDistance = distance
        self.swallowed = swallowed
    }

    /// Every spring has come to rest, so nothing needs redrawing.
    func isSettled(at t: Double) -> Bool {
        guard began != nil else { return true }
        return (merge ?? ended).map { t >= $0 + 1.2 } ?? false
    }

    /// `live` and `distance` are the grab while the fingers are down; after that the release is used.
    func frame(at t: Double, live: CGPoint?, distance: Double?, pill: CGPoint,
               reduceMotion: Bool) -> Frame {
        var f = Frame()
        guard let began else { return f }
        let point = ended == nil ? live ?? released : released
        let near = clamp((260 - (ended == nil ? distance ?? releasedDistance : releasedDistance)) / 140)
        let grown = reduceMotion ? 1 : Self.appear.step(t - began)
        f.beadOpacity = reduceMotion ? clamp((t - began) / 0.2) : 1
        f.bead = point
        f.beadRadius = Self.beadRadius * grown
        f.reach = reduceMotion ? 0 : Self.maxReach * near
        let fading = (merge ?? ended).map { 1 - clamp((t - $0) / 0.5) } ?? 1
        f.target = clamp((t - began) / 0.2) * fading

        if let ended, !swallowed {
            let s = clamp((t - ended) / Self.shrink)
            if reduceMotion { f.beadOpacity *= 1 - s } else { f.beadRadius *= 1 - ease(s) }
            if s >= 1 { f.beadRadius = 0 }
            f.reach *= 1 - Self.relax.step(t - ended)
        } else if let ended, let merge {
            let q = clamp((t - ended) / Self.pullIn), qq = q * q
            if reduceMotion {
                f.beadOpacity *= 1 - q
            } else {
                f.bead = CGPoint(x: lerp(point.x, pill.x, qq), y: lerp(point.y, pill.y, qq))
                f.beadRadius *= 1 - qq
            }
            if t >= merge { f.beadRadius = 0 }
            f.reach *= 1 - Self.relax.step(t - merge)
            if !reduceMotion {
                let k = Self.gulp.kick(t - merge) * Self.gulpDepth
                f.stretch = CGSize(width: 1 + k, height: 1 - 0.4 * k)
                f.glyphPop = 1 + 0.35 * Self.pop.kick(t - merge)
            }
            f.docOpacity = clamp(1 - q * 2.5)
        } else {
            f.docOpacity = 1
        }
        f.docOpacity *= f.beadRadius / Self.beadRadius * f.beadOpacity
        return f
    }
}

private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
private func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
/// The mockup's ease-in-out cubic.
private func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
