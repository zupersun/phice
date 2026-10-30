import Foundation

/// Scroll momentum after the fingers lift, generated on the Mac so the network never stutters it.
///
/// The model is the one WebKit's `MomentumEventDispatcher` uses to stand in for the system's own:
/// the lift speed decays every step, faster once it is slow, in trackpad counts, and each step is
/// then accelerated like a finger's (`ScrollAcceleration`). The numbers are
/// `trackpad-probe --fit momentum` on the built-in trackpad (2026-10-30: 12 flicks, one coasting
/// to a stop, replayed to within 0.3% of its distance); `decay` came out exactly WebKit's.
public struct Momentum: Sendable {
    public struct Parameters: Sendable, Equatable {
        /// Share of the speed kept every 8 ms while it is fast.
        public var decay = 0.975
        /// Share kept every 8 ms at a standstill; blended in linearly below `tailSpeed`.
        public var tailDecay = 0.905
        /// Counts per second (400 per inch) below which momentum starts dying faster.
        public var tailSpeed = 500.0
        /// Lifts slower than this, in counts per second, do not coast. The recording only brackets
        /// it, between slow scrolls lifted at up to 496 and flicks from 4133: the log-scale midpoint.
        public var startSpeed = 1432.0
        /// Momentum ends once both axes are slower than this: half a count per 60 Hz frame.
        public var stopSpeed = 30.0

        public init() {}
    }

    private let p: Parameters
    private var vx: Double, vy: Double

    /// Lift velocity in pad points per second.
    public init(vx: Double, vy: Double, parameters: Parameters = Parameters()) {
        p = parameters
        self.vx = vx * Trackpad.countsPerPoint
        self.vy = vy * Trackpad.countsPerPoint
        if (self.vx * self.vx + self.vy * self.vy).squareRoot() < p.startSpeed {
            self.vx = 0
            self.vy = 0
        }
    }

    /// The finger-equivalent delta in pad points for this step, to be accelerated like a scroll,
    /// or nil once it has decayed.
    public mutating func step(dt: Double) -> (dx: Double, dy: Double)? {
        let speed = (vx * vx + vy * vy).squareRoot()
        let weak = max(0, (p.tailSpeed - speed) / p.tailSpeed)
        let keep = pow(p.decay - (p.decay - p.tailDecay) * weak, max(dt, 0) / 0.008)
        vx *= keep
        vy *= keep
        guard abs(vx) > p.stopSpeed || abs(vy) > p.stopSpeed else { vx = 0; vy = 0; return nil }
        return (vx * dt / Trackpad.countsPerPoint, vy * dt / Trackpad.countsPerPoint)
    }
}
