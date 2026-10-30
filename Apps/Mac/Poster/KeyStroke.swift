import CoreGraphics
import PhiceCore

/// One key press: a virtual key code (HIToolbox's kVK_*, which name ANSI key positions) and the
/// modifiers held with it.
struct KeyStroke: Equatable {
    var code: CGKeyCode
    var flags: CGEventFlags = []

    static let copy = KeyStroke(code: 8, flags: .maskCommand)
    static let cut = KeyStroke(code: 7, flags: .maskCommand)
    static let paste = KeyStroke(code: 9, flags: .maskCommand)
    static let lookUp = KeyStroke(code: 2, flags: [.maskControl, .maskCommand])
    static let quickLook = KeyStroke(code: 49)
    static let escape = KeyStroke(code: 53)
}

extension Shortcut {
    /// The keystroke macOS binds to this gesture, or nil when it is not a keystroke.
    var keystroke: KeyStroke? {
        switch self {
        case .back: KeyStroke(code: 33, flags: .maskCommand)
        case .forward: KeyStroke(code: 30, flags: .maskCommand)
        case .spaceLeft: KeyStroke(code: 123, flags: .maskControl)
        case .spaceRight: KeyStroke(code: 124, flags: .maskControl)
        case .missionControl: KeyStroke(code: 126, flags: .maskControl)
        case .appExpose: KeyStroke(code: 125, flags: .maskControl)
        case .launchpad: KeyStroke(code: 118)
        case .showDesktop: KeyStroke(code: 103)
        // ⌘= rather than ⌘+: every app that zooms in on ⌘+ also takes it without Shift.
        case .zoomIn: KeyStroke(code: 24, flags: .maskCommand)
        case .zoomOut: KeyStroke(code: 27, flags: .maskCommand)
        case .zoomReset: KeyStroke(code: 29, flags: .maskCommand)
        case .notificationCenter: nil
        }
    }
}
