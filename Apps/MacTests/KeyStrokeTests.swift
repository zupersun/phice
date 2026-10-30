import CoreGraphics
import PhiceCore
import Testing
@testable import Phice

// Virtual key codes are HIToolbox's kVK_* values; flags are what the shortcut is bound to.
@Test func shortcutsAreTheKeysMacOSBindsThemTo() {
    let expected: [Shortcut: KeyStroke] = [
        .back: KeyStroke(code: 33, flags: .maskCommand),              // ⌘[
        .forward: KeyStroke(code: 30, flags: .maskCommand),           // ⌘]
        .spaceLeft: KeyStroke(code: 123, flags: .maskControl),        // ⌃←
        .spaceRight: KeyStroke(code: 124, flags: .maskControl),       // ⌃→
        .missionControl: KeyStroke(code: 126, flags: .maskControl),   // ⌃↑
        .appExpose: KeyStroke(code: 125, flags: .maskControl),        // ⌃↓
        .launchpad: KeyStroke(code: 118, flags: []),                  // F4
        .showDesktop: KeyStroke(code: 103, flags: []),                // F11
        .zoomIn: KeyStroke(code: 24, flags: .maskCommand),            // ⌘=
        .zoomOut: KeyStroke(code: 27, flags: .maskCommand),           // ⌘−
        .zoomReset: KeyStroke(code: 29, flags: .maskCommand),         // ⌘0
    ]
    for (shortcut, stroke) in expected { #expect(shortcut.keystroke == stroke, "\(shortcut)") }
}

@Test func notificationCentreIsNotAKeystroke() {
    #expect(Shortcut.notificationCenter.keystroke == nil)
    #expect(Shortcut.allCases.filter { $0.keystroke == nil } == [.notificationCenter])
}

@Test func editingKeysAreCommandCXV() {
    #expect(KeyStroke.copy == KeyStroke(code: 8, flags: .maskCommand))
    #expect(KeyStroke.cut == KeyStroke(code: 7, flags: .maskCommand))
    #expect(KeyStroke.paste == KeyStroke(code: 9, flags: .maskCommand))
    #expect(KeyStroke.lookUp == KeyStroke(code: 2, flags: [.maskControl, .maskCommand]))
    #expect(KeyStroke.quickLook == KeyStroke(code: 49, flags: []))
}

@Test func escapeIsKeyCode53() {
    #expect(KeyStroke.escape == KeyStroke(code: 53))
}
