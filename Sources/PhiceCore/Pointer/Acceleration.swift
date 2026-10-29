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
}

/// Apple's pointer acceleration for one tracking speed.
public struct PointerAcceleration: Sendable {
    public init(curves: [AccelCurve], trackingSpeed: Double) {}

    /// Pad-point delta over `dt` seconds to screen points. Stub: identity until the pointer work lands.
    public mutating func apply(dx: Double, dy: Double, dt: Double) -> (dx: Double, dy: Double) { (dx, dy) }
}

/// Scroll momentum after the fingers lift, generated on the Mac so the network never stutters it.
public struct Momentum: Sendable {
    public init(vx: Double, vy: Double) {}

    /// The scroll delta to post for this step, or nil once it has decayed. Stub: no momentum.
    public mutating func step(dt: Double) -> (dx: Double, dy: Double)? { nil }
}
