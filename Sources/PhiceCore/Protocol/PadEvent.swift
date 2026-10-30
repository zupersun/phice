public enum MouseButton: String, Codable, Sendable {
    case left, right
}

public enum ScrollPhase: String, Codable, Sendable {
    case began, changed, ended
}

/// Gestures macOS keeps private to its own trackpad, performed through the shortcut they trigger.
public enum Shortcut: String, Codable, Sendable, CaseIterable {
    case back, forward                  // swipe between pages: ⌘[ ⌘]
    case spaceLeft, spaceRight          // swipe between full-screen apps: ⌃← ⌃→
    case missionControl, appExpose      // ⌃↑ ⌃↓
    case launchpad                      // Apps on macOS 26+
    case showDesktop
    case notificationCenter
    case zoomIn, zoomOut, zoomReset     // pinch and smart zoom: ⌘+ ⌘− ⌘0
}

/// What a drop into the pill does with the selection.
public enum DropAction: Codable, Sendable, Equatable {
    case copy
    case cut
    case shortcut(name: String)
}

/// What the fingers mean, sent phone → Mac. Deltas are pad points before acceleration.
public enum PadEvent: Codable, Sendable, Equatable {
    case move(dx: Double, dy: Double, t: Double)
    case button(MouseButton, down: Bool, clicks: Int)
    case scroll(dx: Double, dy: Double, phase: ScrollPhase, t: Double)
    /// Lift velocity in pad points per second; the Mac runs momentum from it locally.
    case scrollEnded(vx: Double, vy: Double)
    /// A finger landed during momentum.
    case momentumStop
    case shortcut(Shortcut)
    /// Look Up at the cursor, or Quick Look when Finder is frontmost.
    case forceClick
    /// The copy gesture holds the cursor still while the fingers carry the item to the pill.
    case freeze(Bool)
    /// Lifted over the pill: perform the action, then release the click where it was pressed.
    case drop(DropAction)
    /// An item dragged out of the pill or the column: click at the cursor, then ⌘V.
    case paste(itemID: String)
}

/// How the recogniser read one finger; it drives the glow and the haptics. A press goes
/// `live → pressed` (the button is down), a deep press `pressed → force`, and back to `live`, or
/// gone on lifting, when the button comes up.
public enum TouchVerdict: String, Codable, Sendable {
    case live, pressed, force, rejected
}
