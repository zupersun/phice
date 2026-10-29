import CoreGraphics
import PhiceCore

/// The hold menu, top to bottom along the edge.
enum MenuItem: Int, CaseIterable, Identifiable {
    case power, clipboard, settings
    var id: Int { rawValue }
}

/// The hold menu's selection, both ways: release then tap, or keep holding and slide.
struct HoldMenu: Equatable {
    enum Phase { case closed, held, open, pressing }

    /// A finger must travel this far from where the hold opened the menu before the item under it
    /// highlights; otherwise releasing straight after the hold would always pick the middle item.
    static let slop: CGFloat = 10

    private(set) var phase = Phase.closed
    private(set) var highlight: MenuItem?
    private var origin: CGPoint?

    var isOpen: Bool { phase != .closed }

    /// The pill was held: the menu opens under the finger, which is still down.
    mutating func open(at point: CGPoint) {
        phase = .held
        highlight = nil
        origin = point
    }

    mutating func move(to point: CGPoint, over item: MenuItem?) {
        guard phase == .held || phase == .pressing else { return }
        if let origin {
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.slop else { return }
            self.origin = nil
        }
        highlight = item
    }

    /// A new finger while the menu is open: on an item it presses it, anywhere else it collapses.
    mutating func touchDown(over item: MenuItem?) {
        guard phase == .open else { return }
        guard let item else { return close() }
        phase = .pressing
        highlight = item
    }

    /// The finger lifted. Returns the item it chose, if any. Lifting over nothing leaves the menu
    /// open for a tap; the state button keeps it open so the new state can be seen.
    mutating func lift() -> MenuItem? {
        guard phase == .held || phase == .pressing else { return nil }
        let chosen = highlight
        highlight = nil
        origin = nil
        phase = chosen == nil || chosen == .power ? .open : .closed
        return chosen
    }

    mutating func close() {
        self = HoldMenu()
    }
}

/// What a touch on the pill or the column turns out to be: a hold, or a drag that leaves before it.
struct Press: Equatable {
    enum Kind { case hold, drag }

    static let holdDelay = 0.4
    static let slop: CGFloat = 10

    let start: CGPoint
    let t0: Double
    private(set) var kind: Kind?

    init(at point: CGPoint, t: Double) {
        start = point
        t0 = t
    }

    /// Returns `.drag` the moment the finger leaves the slop before the hold fires.
    mutating func move(to point: CGPoint, t: Double) -> Kind? {
        guard kind == nil, hypot(point.x - start.x, point.y - start.y) > Self.slop else { return nil }
        kind = .drag
        return kind
    }

    /// Returns `.hold` once the finger has stayed put for `holdDelay`.
    mutating func tick(_ t: Double) -> Kind? {
        guard kind == nil, t - t0 >= Self.holdDelay - 1e-9 else { return nil }
        kind = .hold
        return kind
    }
}

/// An item dragged out of the pill or the column: the cursor follows the finger over the pad, and
/// lifting there pastes it. Lifting back where it came from does nothing.
struct DragOut: Equatable {
    let itemID: String
    private(set) var last: CGPoint

    init(itemID: String, at point: CGPoint) {
        self.itemID = itemID
        last = point
    }

    mutating func move(to point: CGPoint, overPad: Bool, t: Double) -> PadEvent? {
        defer { last = point }
        guard overPad else { return nil }
        return .move(dx: point.x - last.x, dy: point.y - last.y, t: t)
    }

    func lift(overPad: Bool) -> PadEvent? {
        overPad ? .paste(itemID: itemID) : nil
    }
}
