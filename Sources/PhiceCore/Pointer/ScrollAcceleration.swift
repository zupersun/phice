/// Apple's scroll acceleration (`IOHIDScrollAccelerator`), each axis on its own: the gain comes from
/// the average size of the last few scroll steps, so a sustained fast scroll covers more ground.
///
/// One deliberate difference: each step is first rescaled to what the trackpad would have reported
/// in one of its own 120 Hz reports, so the result does not depend on how often the phone sends.
/// Apple's version sees the per-report delta directly, and a phone sending at 60 Hz would double it.
public struct ScrollAcceleration: Sendable {
    /// `HIDTrackpadScrollAcceleration` on a Mac with the scrolling speed left at its default.
    public static let defaultSpeed = 0.3125

    private let curve: ParametricCurve
    private var x = Axis(), y = Axis()

    public init(curves: [AccelCurve], speed: Double = defaultSpeed) {
        curve = ParametricCurve(curves, index: speed)
    }

    /// Finger delta in pad points over `dt` seconds (nil for the first step of a gesture) to pixels,
    /// keeping its sign.
    public mutating func apply(dx: Double, dy: Double, dt: Double?) -> (dx: Double, dy: Double) {
        let dt = dt ?? Trackpad.reportInterval
        return (x.apply(dx * Trackpad.countsPerPoint, dt: dt, curve),
                y.apply(dy * Trackpad.countsPerPoint, dt: dt, curve))
    }

    /// Forget the previous gesture's speed.
    public mutating func reset() {
        x = Axis()
        y = Axis()
    }

    private struct Axis {
        private var history: [(dt: Double, size: Double)] = []
        private var positive: Bool?
        /// Time since this axis last moved; Apple only times the steps that move it.
        private var idle = 0.0

        mutating func apply(_ value: Double, dt: Double, _ curve: ParametricCurve) -> Double {
            guard value != 0 else { idle += dt; return 0 }
            let dt = idle + dt
            idle = 0
            let size = abs(value) * Trackpad.reportInterval / max(dt, Trackpad.reportInterval / 2)
            if positive != (value > 0) || dt > 0.5 {
                history.removeAll()
                positive = value > 0
            }
            history.append((dt, size))
            if history.count > 8 { history.removeFirst() }
            // Average back over at most half a second, stopping at a step that came after a pause.
            var span = 0.0, total = 0.0, count = 0.0
            for step in history.reversed() {
                total += step.size
                count += 1
                if step.dt > 0.15 { break }
                span += step.dt
                if span >= 0.5 { break }
            }
            let ms = Trackpad.reportInterval * 1000
            let a = 2.0 / 65536, b = 955.0 / 65536, c = 98369.0 / 65536
            let velocity = max((a * ms * ms - b * ms + c) * total / count, 1.0 / 65536)
            // Apple then scales by 0.1 into wheel lines; the window server turns those back into pixels.
            return value * curve.multiplier(velocity) / velocity
        }
    }
}
