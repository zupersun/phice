import Foundation
import PhiceCore

/// The Mac's own trackpad settings, from the preference domains System Settings writes. A key the
/// Mac does not have leaves the matching `TrackpadSettings` field at macOS's default.
enum TrackpadSettingsReader {
    private static let builtIn = "com.apple.AppleMultitouchTrackpad"
    private static let bluetooth = "com.apple.driver.AppleBluetoothMultitouch.trackpad"

    static func current() -> TrackpadSettings {
        let pad = domain(builtIn)
        let globals = ["com.apple.trackpad.scaling", "com.apple.swipescrolldirection",
                       "com.apple.trackpad.forceClick", "AppleEnableSwipeNavigateWithScrolls"]
        let global = globals.reduce(into: [String: Any]()) {
            $0[$1] = CFPreferencesCopyAppValue($1 as CFString, kCFPreferencesAnyApplication)
        }
        let dockKey = "showAppExposeGestureEnabled"
        let dockValue = CFPreferencesCopyAppValue(dockKey as CFString, "com.apple.dock" as CFString)
        let dock = dockValue.map { [dockKey: $0] } ?? [:]
        return settings(trackpad: pad.isEmpty ? domain(bluetooth) : pad, global: global, dock: dock)
    }

    /// Values arrive as Int, Bool or Double depending on who wrote them, so everything goes
    /// through NSNumber.
    static func settings(trackpad: [String: Any], global: [String: Any],
                         dock: [String: Any]) -> TrackpadSettings {
        var s = TrackpadSettings()
        func number(_ d: [String: Any], _ key: String) -> NSNumber? { d[key] as? NSNumber }
        func int(_ key: String) -> Int? { number(trackpad, key)?.intValue }
        func flag(_ d: [String: Any], _ key: String) -> Bool? {
            number(d, key).map { $0.intValue != 0 }
        }
        func fingers(_ three: Int?, _ four: Int?, on value: Int) -> Fingers? {
            three == value ? .three : four == value ? .four : nil
        }

        if let v = number(global, "com.apple.trackpad.scaling")?.doubleValue {
            s.trackingSpeed = min(max(v, 0), 3)
        }
        s.naturalScrolling = flag(global, "com.apple.swipescrolldirection") ?? s.naturalScrolling
        s.tapToClick = int("Clicking").map { $0 != 0 } ?? s.tapToClick
        s.dragLock = int("DragLock").map { $0 != 0 } ?? s.dragLock
        s.threeFingerDrag = int("TrackpadThreeFingerDrag").map { $0 != 0 } ?? s.threeFingerDrag
        s.momentumScroll = int("TrackpadMomentumScroll").map { $0 != 0 } ?? s.momentumScroll
        s.pinchZoom = int("TrackpadPinch").map { $0 != 0 } ?? s.pinchZoom
        s.smartZoom = int("TrackpadTwoFingerDoubleTapGesture").map { $0 != 0 } ?? s.smartZoom

        // A corner click replaces the two-finger one in System Settings.
        let corner = int("TrackpadCornerSecondaryClick"), twoFinger = int("TrackpadRightClick")
        if corner != nil || twoFinger != nil {
            s.secondaryClick = corner == 1 ? .bottomLeft : corner == 2 ? .bottomRight
                : (twoFinger ?? 1) != 0 ? .twoFingers : .off
        }

        // Look Up is a force click unless the Mac moved it to a three-finger tap or switched it off.
        s.lookUpForceClick = int("TrackpadThreeFingerTapGesture") != 2
            && (flag(global, "com.apple.trackpad.forceClick") ?? true)

        // 1 is "swipe between pages", 2 is "between full-screen apps".
        let twoPages = flag(global, "AppleEnableSwipeNavigateWithScrolls") ?? true
        let threePages = int("TrackpadThreeFingerHorizSwipeGesture") == 1
        s.swipePages = twoPages && threePages ? .both : twoPages ? .twoFingerScroll
            : threePages ? .threeFingerSwipe : .off

        let horizontal = (int("TrackpadThreeFingerHorizSwipeGesture"),
                          int("TrackpadFourFingerHorizSwipeGesture"))
        if horizontal.0 != nil || horizontal.1 != nil {
            s.swipeSpaces = fingers(horizontal.0, horizontal.1, on: 2)
        }
        let vertical = (int("TrackpadThreeFingerVertSwipeGesture"),
                        int("TrackpadFourFingerVertSwipeGesture"))
        if vertical.0 != nil || vertical.1 != nil {
            s.missionControl = fingers(vertical.0, vertical.1, on: 2)
        }
        // App Exposé shares the vertical swipe; the Dock holds its own switch.
        if flag(dock, "showAppExposeGestureEnabled") == true {
            s.appExpose = fingers(vertical.0, vertical.1, on: 2)
        }

        if let v = int("TrackpadTwoFingerFromRightEdgeSwipeGesture") { s.notificationCenter = v == 3 }
        if let v = int("TrackpadFourFingerPinchGesture") { s.launchpad = v == 2 }
        if let v = int("TrackpadFiveFingerPinchGesture") { s.showDesktop = v == 2 }
        return s
    }

    private static func domain(_ id: String) -> [String: Any] {
        CFPreferencesAppSynchronize(id as CFString)
        let (user, host) = (kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let keys = CFPreferencesCopyKeyList(id as CFString, user, host) else { return [:] }
        return CFPreferencesCopyMultiple(keys, id as CFString, user, host) as? [String: Any] ?? [:]
    }
}
