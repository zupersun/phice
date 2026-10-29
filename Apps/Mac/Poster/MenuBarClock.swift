import AppKit
import ApplicationServices

/// Notification Centre has no keystroke; pressing the menu bar clock opens it. Uses Accessibility,
/// and does nothing when the clock cannot be found.
enum MenuBarClock {
    @discardableResult
    static func press() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for bundle in ["com.apple.controlcenter", "com.apple.systemuiserver"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                guard let bar = element(root, "AXExtrasMenuBar"),
                      let items = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                let clock = "com.apple.menuextra.clock"
                for item in items where value(item, "AXIdentifier") as? String == clock {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &out)
        return result == .success ? out : nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(parent, attribute), CFGetTypeID(v) == AXUIElementGetTypeID()
        else { return nil }
        return (v as! AXUIElement)
    }
}
