/// One finger as the phone saw it. Coordinates are points in the landscape pad, origin top-left.
public struct Touch: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case began, moved, stationary, ended, cancelled
    }

    public var id: UInt16
    public var x: Double
    public var y: Double
    /// `UITouch.majorRadius` in points: the contact size that force press and rejection read.
    public var radius: Double
    public var phase: Phase
    /// Phone monotonic seconds.
    public var t: Double

    public init(id: UInt16, x: Double, y: Double, radius: Double, phase: Phase, t: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.radius = radius
        self.phase = phase
        self.t = t
    }
}

/// Every finger on the pad at one instant, including ones that just lifted.
public struct TouchFrame: Codable, Sendable, Equatable {
    public var t: Double
    public var touches: [Touch]

    public init(t: Double, touches: [Touch]) {
        self.t = t
        self.touches = touches
    }
}
