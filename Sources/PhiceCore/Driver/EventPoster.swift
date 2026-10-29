public enum MomentumPhase: String, Codable, Sendable {
    case begin, `continue`, end
}

/// What the Mac can do to the cursor. The app implements it with CGEvent; tests use `FakePoster`.
public protocol EventPoster: AnyObject {
    var cursor: (x: Double, y: Double) { get }
    /// Relative move in screen points; the poster clamps to the displays. `dragging` posts drag events.
    func move(dx: Double, dy: Double, dragging: MouseButton?)
    func moveTo(x: Double, y: Double, dragging: MouseButton?)
    func button(_ button: MouseButton, down: Bool, clicks: Int)
    func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?)
    func shortcut(_ shortcut: Shortcut)
    /// Look Up at the cursor, or Quick Look when Finder is frontmost.
    func forceClick()
    /// Copy, cut or run a shortcut on the selection; true when the pasteboard changed.
    func perform(_ action: DropAction) -> Bool
    /// Put a stored item on the pasteboard and send ⌘V. The driver clicks at the cursor first.
    func paste(itemID: String)
}

/// Records every call, for tests and `fake-phone`.
public final class FakePoster: EventPoster {
    public enum Call: Equatable, Sendable {
        case move(dx: Double, dy: Double, dragging: MouseButton?)
        case moveTo(x: Double, y: Double, dragging: MouseButton?)
        case button(MouseButton, down: Bool, clicks: Int)
        case scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?)
        case shortcut(Shortcut)
        case forceClick
        case perform(DropAction)
        case paste(itemID: String)
    }

    public private(set) var calls: [Call] = []
    public var cursor: (x: Double, y: Double) = (0, 0)
    public var performSucceeds = true

    public init() {}

    public func move(dx: Double, dy: Double, dragging: MouseButton?) {
        cursor = (cursor.x + dx, cursor.y + dy)
        calls.append(.move(dx: dx, dy: dy, dragging: dragging))
    }

    public func moveTo(x: Double, y: Double, dragging: MouseButton?) {
        cursor = (x, y)
        calls.append(.moveTo(x: x, y: y, dragging: dragging))
    }

    public func button(_ button: MouseButton, down: Bool, clicks: Int) {
        calls.append(.button(button, down: down, clicks: clicks))
    }

    public func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?) {
        calls.append(.scroll(dx: dx, dy: dy, phase: phase, momentum: momentum))
    }

    public func shortcut(_ shortcut: Shortcut) { calls.append(.shortcut(shortcut)) }

    public func forceClick() { calls.append(.forceClick) }

    public func perform(_ action: DropAction) -> Bool {
        calls.append(.perform(action))
        return performSucceeds
    }

    public func paste(itemID: String) { calls.append(.paste(itemID: itemID)) }

    public func clear() { calls.removeAll() }
}
