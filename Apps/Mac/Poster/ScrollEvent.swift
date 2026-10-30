import CoreGraphics
import PhiceCore

/// Builds the continuous pixel scroll events that stand in for a trackpad's.
enum ScrollEvent {
    /// Stamped into kCGEventSourceUserData on every scroll event posted, so `ScrollWatch` can tell
    /// ours from the trackpad's. The low byte says which signs went in.
    private static let tagBase: Int64 = 0x5048494345 << 8   // "PHICE"

    /// Bits 1 and 2: vertical present, vertical positive. Bits 4 and 8: the same for horizontal.
    static func tag(dx: Int, dy: Int) -> Int64 {
        var bits: Int64 = 0
        if dy != 0 { bits |= dy > 0 ? 3 : 1 }
        if dx != 0 { bits |= dx > 0 ? 12 : 4 }
        return tagBase | bits
    }

    static func isOurs(_ tag: Int64) -> Bool { tag & ~0xFF == tagBase }

    /// `dx`/`dy` go into the event as given (CGEvent's signs) and the tag records those same signs.
    /// What a reverser did is then what came out compared with what went in. The tag is set once:
    /// CGEvent ignores any later write to kCGEventSourceUserData.
    static func make(dx: Int, dy: Int, phase: ScrollPhase?, momentum: MomentumPhase?) -> CGEvent {
        // wheelCount 2 is valid, so this cannot fail.
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.map(raw) ?? 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.map(raw) ?? 0)
        event.setIntegerValueField(.eventSourceUserData, value: tag(dx: dx, dy: dy))
        return event
    }

    // kCGScrollPhaseBegan/Changed/Ended and kCGMomentumScrollPhaseBegin/Continue/End.
    private static func raw(_ phase: ScrollPhase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        }
    }

    private static func raw(_ phase: MomentumPhase) -> Int64 {
        switch phase {
        case .begin: 1
        case .continue: 2
        case .end: 3
        }
    }
}

/// Pixel events are whole numbers; the fraction a slow scroll leaves behind is carried to the next.
struct ScrollAccumulator {
    private var x = 0.0
    private var y = 0.0

    mutating func take(dx: Double, dy: Double) -> (dx: Int, dy: Int) {
        x += dx.isFinite ? dx : 0
        y += dy.isFinite ? dy : 0
        let whole = (dx: Self.whole(x), dy: Self.whole(y))
        x -= Double(whole.dx)
        y -= Double(whole.dy)
        return whole
    }

    /// Truncates toward zero, so both signs behave alike; the bound keeps Int() from trapping.
    private static func whole(_ v: Double) -> Int { Int(max(-1e6, min(1e6, v)).rounded(.towardZero)) }

    mutating func reset() { x = 0; y = 0 }
}
