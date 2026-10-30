import Foundation
import PhiceCore

/// How one finger's light looks this frame. Radii in points.
struct GlowShape: Equatable {
    /// The light's radius; it fades to nothing a little before reaching it.
    var light: Double
    /// The extra light of a force press, drawn over the first, and how much of it is left.
    var bloom: Double
    var bloomAlpha: Double
    /// A rejected touch: a dim ring instead of a light.
    var hollow: Bool
}

/// One finger's light over time: it eases toward the contact size, blooms on a force press, then
/// lets the bloom spread out and fade as the finger eases off. Pure, so the timing is testable.
struct GlowState {
    /// The light reaches this many contact radii, so it shows around the finger, not only under it.
    static let spread = 2.4
    static let bloomTime = 0.35
    /// How much smaller than its peak the contact gets before the bloom is gone.
    static let disperseAt = 0.3
    /// How much of a deep press's bloom a plain press shows.
    static let pressLift = 0.35

    private var radius: Double?
    private var last: (t: Double, verdict: TouchVerdict)?
    private var press: (t: Double, peak: Double)?
    private var dispersed = 0.0

    mutating func step(contact: Double, verdict: TouchVerdict, now: Double) -> GlowShape {
        let dt = max(0, now - (last?.t ?? now))
        // The digitizer reports contact size in steps of 12 pt or so; easing over ~80 ms turns
        // them into breathing.
        let r = radius.map { $0 + (contact - $0) * (1 - exp(-dt / 0.08)) } ?? contact
        radius = r
        if verdict == .force, last?.verdict != .force {
            press = (now, r)
            dispersed = 0
        }
        // Released: the light drops back at once, with the release click.
        if verdict == .live || verdict == .rejected { press = nil }
        last = (now, verdict)
        let light = r * Self.spread
        guard verdict != .rejected else {
            return GlowShape(light: light, bloom: 0, bloomAlpha: 0, hollow: true)
        }
        guard var press else {
            let lift = verdict == .pressed ? Self.pressLift : 0
            return GlowShape(light: light, bloom: light * (1 + 0.55 * lift), bloomAlpha: 0.6 * lift,
                             hollow: false)
        }
        press.peak = max(press.peak, r)
        self.press = press
        let rise = min(1, (now - press.t) / Self.bloomTime)
        // Easing off never brings it back: the click stands, as on a MacBook.
        if rise == 1 { dispersed = max(dispersed, min(1, (1 - r / press.peak) / Self.disperseAt)) }
        // A deep press is a press too, so it blooms from the pressed light instead of dipping.
        let grow = max(Self.pressLift, 1 - pow(1 - rise, 3))
        return GlowShape(light: light, bloom: light * (1 + 0.55 * grow + 0.8 * dispersed),
                         bloomAlpha: 0.6 * grow * (1 - dispersed), hollow: false)
    }
}
