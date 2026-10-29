public enum SecondaryClick: String, Codable, Sendable {
    case twoFingers, bottomRight, bottomLeft, off
}

public enum Fingers: Int, Codable, Sendable {
    case three = 3, four = 4
}

public enum SwipePages: String, Codable, Sendable {
    case twoFingerScroll, threeFingerSwipe, both, off
}

/// The Mac's own trackpad settings (System Settings › Trackpad), read from
/// `com.apple.AppleMultitouchTrackpad`, `com.apple.trackpad.scaling` and
/// `com.apple.swipescrolldirection`. Defaults are macOS's. A nil gesture is switched off.
public struct TrackpadSettings: Codable, Sendable, Equatable {
    /// `com.apple.trackpad.scaling`, 0...3. The default is what macOS applies when the slider was
    /// never moved (`HIDTrackpadAcceleration` 45056 / 65536).
    public var trackingSpeed = 0.6875
    /// The trackpad's scrolling speed, 0...3 (`HIDTrackpadScrollAcceleration`; default 20480 / 65536).
    public var scrollSpeed = 0.3125
    public var tapToClick = true
    public var dragLock = false
    public var threeFingerDrag = false
    public var secondaryClick = SecondaryClick.twoFingers
    public var naturalScrolling = true
    public var momentumScroll = true
    public var pinchZoom = true
    public var smartZoom = true
    /// Force click opens Look Up; off when the Mac uses a three-finger tap for it instead.
    public var lookUpForceClick = true
    public var swipePages = SwipePages.twoFingerScroll
    public var swipeSpaces: Fingers? = .three
    public var missionControl: Fingers? = .three
    public var appExpose: Fingers? = nil
    public var notificationCenter = true
    public var launchpad = true
    public var showDesktop = true

    public init() {}
}
