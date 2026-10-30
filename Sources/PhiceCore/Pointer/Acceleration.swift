import Foundation

/// One of Apple's parametric curves as ioreg lists them under `HIDAccelCurves` or
/// `HIDScrollAccelCurves`. ioreg stores 16.16 fixed point; these are the decoded values.
public struct AccelCurve: Codable, Sendable, Equatable {
    /// The tracking speed this curve belongs to (`HIDAccelIndex`).
    public var index: Double
    public var gainLinear: Double
    public var gainParabolic: Double
    public var gainCubic: Double
    public var gainQuartic: Double
    public var tangentSpeedLinear: Double
    public var tangentSpeedParabolicRoot: Double

    /// From one ioreg dictionary; absent gains are zero.
    public init(ioreg d: [String: Int]) {
        func f(_ key: String) -> Double { Double(d[key] ?? 0) / 65536 }
        index = f("HIDAccelIndex")
        gainLinear = f("HIDAccelGainLinear")
        gainParabolic = f("HIDAccelGainParabolic")
        gainCubic = f("HIDAccelGainCubic")
        gainQuartic = f("HIDAccelGainQuartic")
        tangentSpeedLinear = f("HIDAccelTangentSpeedLinear")
        tangentSpeedParabolicRoot = f("HIDAccelTangentSpeedParabolicRoot")
    }

    var isValid: Bool { gainLinear != 0 || gainParabolic != 0 || gainCubic != 0 || gainQuartic != 0 }
}

/// The units Apple's curves are written in. The phone sends pad points; the built-in trackpad's
/// curves expect its own counts, which ioreg gives as `HIDPointerResolution` and
/// `HIDScrollResolution` (both 400 per inch) and `HIDPointerReportRate` (120 Hz).
enum Trackpad {
    /// iPhones are ~460 ppi at 3x, so one point is about 1/153 inch.
    static let pointsPerInch = 153.0
    static let countsPerInch = 400.0
    static let countsPerPoint = countsPerInch / pointsPerInch
    static let reportInterval = 1.0 / 120
}

/// IOHIDFamily's `IOHIDParametricAcceleration`: the curve for one tracking speed, interpolated
/// between the two listed curves around it, mapping a speed in counts per report to points.
struct ParametricCurve: Sendable {
    private var c: AccelCurve
    private var tangent = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
    private var m = (0.0, 0.0), b = (0.0, 0.0)

    init(_ curves: [AccelCurve], index: Double) {
        // Without curves, a plain 96-points-per-inch line (Apple would fall back to a table).
        let valid = curves.filter(\.isValid)
        let curves = valid.isEmpty ? [AccelCurve(ioreg: ["HIDAccelGainLinear": 65536])] : valid
        let i = curves.lastIndex { index >= $0.index } ?? 0
        c = curves[i]
        if c.index < index, i + 1 < curves.count {
            let lo = curves[i], hi = curves[i + 1]
            let r = (index - lo.index) / (hi.index - lo.index)
            let keys: [WritableKeyPath<AccelCurve, Double>] = [
                \.index, \.gainLinear, \.gainParabolic, \.gainCubic, \.gainQuartic,
                \.tangentSpeedLinear, \.tangentSpeedParabolicRoot,
            ]
            for key in keys {
                c[keyPath: key] = lo[keyPath: key] + r * (hi[keyPath: key] - lo[keyPath: key])
            }
        }
        // Apple raises gain*x, not x, to each power; the slope below is consistent with that.
        func slope(_ x: Double) -> Double {
            c.gainLinear + 2 * x * pow(c.gainParabolic, 2) + 3 * pow(x, 2) * pow(c.gainCubic, 3)
                + 4 * pow(x, 3) * pow(c.gainQuartic, 4)
        }
        if c.tangentSpeedLinear != 0 {
            let x0 = c.tangentSpeedLinear
            m.0 = slope(x0)
            b.0 = quartic(x0) - m.0 * x0
            tangent.0 = x0
            if c.tangentSpeedParabolicRoot != 0 {
                let x1 = c.tangentSpeedParabolicRoot, y1 = m.0 * x1 + b.0
                m.1 = 2 * y1 * m.0
                b.1 = pow(y1, 2) - m.1 * x1
                tangent.1 = x1
            }
        } else if c.tangentSpeedParabolicRoot != 0 {
            let x1 = c.tangentSpeedParabolicRoot
            m.1 = slope(x1)
            b.1 = pow(quartic(x1), 2) - m.1 * x1
            tangent.0 = x1
        }
    }

    private func quartic(_ x: Double) -> Double {
        c.gainLinear * x + pow(c.gainParabolic * x, 2) + pow(c.gainCubic * x, 3)
            + pow(c.gainQuartic * x, 4)
    }

    /// Apple's `multiplier(value)`: despite the name, the accelerated speed.
    func multiplier(_ value: Double) -> Double {
        // The curves assume a 67 Hz frame and a 96 dpi screen; Apple's comments do not say why 67.
        let v = value / (Trackpad.countsPerInch / 67)
        let y: Double
        if v <= tangent.0 {
            y = quartic(v)
        } else if v <= tangent.1, tangent.0 == c.tangentSpeedLinear {
            y = m.0 * v + b.0
        } else {
            y = (m.1 * v + b.1).squareRoot()
        }
        return y * 96 / 67
    }
}

/// Apple's pointer acceleration for one tracking speed (`IOHIDPointerAccelerator`).
public struct PointerAcceleration: Sendable {
    private let curve: ParametricCurve

    /// `trackingSpeed` is `com.apple.trackpad.scaling`, which picks the curve by `HIDAccelIndex`.
    public init(curves: [AccelCurve], trackingSpeed: Double) {
        curve = ParametricCurve(curves, index: trackingSpeed)
    }

    /// Pad-point delta over `dt` seconds to screen points.
    public mutating func apply(dx: Double, dy: Double, dt: Double) -> (dx: Double, dy: Double) {
        let x = dx * Trackpad.countsPerPoint, y = dy * Trackpad.countsPerPoint
        let distance = (x * x + y * y).squareRoot()
        // Speed is counts per trackpad report. Apple counts a report that comes early as a whole
        // one, since its trackpad never reports faster than 120 Hz; the phone samples at 240 Hz,
        // and read that way its steps got half the speed and a third less travel. So a shorter
        // step counts as the fraction of a report it is, down to a quarter so a glitch cannot fake
        // a flick.
        let reports = dt > 0 ? max(dt, Trackpad.reportInterval / 4) / Trackpad.reportInterval : 1
        let perReport = reports < 1
            ? (distance / reports).rounded(.down) : distance.rounded(.down) / reports
        let velocity = max(perReport, 1.0 / 65536)
        let gain = curve.multiplier(velocity) / velocity
        return (x * gain, y * gain)
    }
}
