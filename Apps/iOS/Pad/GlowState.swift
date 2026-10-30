import Foundation
import PhiceCore

/// How one finger's light looks this frame. Radii in points.
struct GlowShape: Equatable {
    /// The light's radius; it fades to nothing a little before reaching it.
    var light: Double
    /// The extra light of a press, drawn over the first, and how much of it shows.
    var bloom: Double
    var bloomAlpha: Double
    /// A rejected touch: a dim ring instead of a light.
    var hollow: Bool
}

/// One finger's light over time: it eases toward the contact size and lifts while the finger
/// presses. Pure, so the timing is testable.
struct GlowState {
    /// The light reaches this many contact radii, so it shows around the finger, not only under it.
    static let spread = 2.4
    /// How much a press lifts the light.
    static let pressLift = 0.35

    private var radius: Double?
    private var last: Double?

    mutating func step(contact: Double, verdict: TouchVerdict, now: Double) -> GlowShape {
        let dt = max(0, now - (last ?? now))
        // The digitizer reports contact size in steps of 12 pt or so; easing over ~80 ms turns
        // them into breathing.
        let r = radius.map { $0 + (contact - $0) * (1 - exp(-dt / 0.08)) } ?? contact
        radius = r
        last = now
        let light = r * Self.spread
        guard verdict != .rejected else {
            return GlowShape(light: light, bloom: 0, bloomAlpha: 0, hollow: true)
        }
        // Released, the light drops back at once, with the release click.
        let lift = verdict == .pressed ? Self.pressLift : 0
        return GlowShape(light: light, bloom: light * (1 + 0.55 * lift), bloomAlpha: 0.6 * lift,
                         hollow: false)
    }
}
