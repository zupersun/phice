/// Which edge of the pad the pill sits on. The drop zone is the fifth of the pad on that side.
public enum Side: String, Codable, Sendable {
    case left, right
}

public struct PadGeometry: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var pillSide: Side
    public var dropZoneFraction: Double

    public init(width: Double, height: Double, pillSide: Side = .left, dropZoneFraction: Double = 0.2) {
        self.width = width
        self.height = height
        self.pillSide = pillSide
        self.dropZoneFraction = dropZoneFraction
    }
}

/// The copy gesture in progress: where the held item's bead is, and whether it is over the drop zone.
public struct Grab: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var inZone: Bool

    public init(x: Double, y: Double, inZone: Bool) {
        self.x = x
        self.y = y
        self.inZone = inZone
    }
}

/// Turns raw touches into what they mean. Pure: time comes only from frames and `tick(now:)`.
/// Touches that begin on the pill never reach it; the pill's own view owns those.
public struct Recogniser: Sendable {
    public var settings: TrackpadSettings
    public var geometry: PadGeometry
    public var dropAction: DropAction = .copy
    public private(set) var verdicts: [UInt16: TouchVerdict] = [:]
    public private(set) var grab: Grab?

    public init(settings: TrackpadSettings, geometry: PadGeometry) {
        self.settings = settings
        self.geometry = geometry
    }

    /// Stub until the gesture engine lands.
    public mutating func feed(_ frame: TouchFrame) -> [PadEvent] { [] }

    /// Time-based transitions: tap timeouts, tap-to-drag grace, force press settling.
    public mutating func tick(now: Double) -> [PadEvent] { [] }
}
