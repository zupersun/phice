public enum SecondaryClick: String, Codable, Sendable {
    case twoFingers, bottomRight, bottomLeft, off
}

public enum Fingers: Int, Codable, Sendable, Hashable {
    case three = 3, four = 4
}

public enum SwipePages: String, Codable, Sendable {
    case twoFingerScroll, threeFingerSwipe, both, off
}

/// The Mac's own trackpad settings (System Settings › Trackpad), read from
/// `com.apple.AppleMultitouchTrackpad`, `com.apple.trackpad.scaling` and
/// `com.apple.swipescrolldirection`. Defaults are macOS's. A swipe with no finger counts is off.
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
    /// The finger counts each swipe answers to: macOS keeps a switch for three and one for four,
    /// and ships with both on.
    public var swipeSpaces: Set<Fingers> = [.three, .four]
    public var missionControl: Set<Fingers> = [.three, .four]
    public var appExpose: Set<Fingers> = []
    public var notificationCenter = true
    public var launchpad = true
    public var showDesktop = true

    public init() {}
}

/// The phone (App Store) and the Mac agent (download) update separately, so a settings message may
/// lack a field the receiver knows or carry one it doesn't: missing keys keep their defaults and
/// unknown ones are ignored. A switched-off swipe is written as an empty list, never left out, so
/// it cannot come back as the default.
extension TrackpadSettings {
    enum CodingKeys: String, CodingKey {
        case trackingSpeed, scrollSpeed, tapToClick, dragLock, threeFingerDrag, secondaryClick
        case naturalScrolling, momentumScroll, pinchZoom, smartZoom, lookUpForceClick, swipePages
        case swipeSpaces, missionControl, appExpose, notificationCenter, launchpad, showDesktop
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws {
            if c.contains(key) { value = try c.decode(T.self, forKey: key) }
        }
        try read(.trackingSpeed, &trackingSpeed)
        try read(.scrollSpeed, &scrollSpeed)
        try read(.tapToClick, &tapToClick)
        try read(.dragLock, &dragLock)
        try read(.threeFingerDrag, &threeFingerDrag)
        try read(.secondaryClick, &secondaryClick)
        try read(.naturalScrolling, &naturalScrolling)
        try read(.momentumScroll, &momentumScroll)
        try read(.pinchZoom, &pinchZoom)
        try read(.smartZoom, &smartZoom)
        try read(.lookUpForceClick, &lookUpForceClick)
        try read(.swipePages, &swipePages)
        // Each swipe once held one finger count or null; overrides the phone saved then still load.
        func fingers(_ key: CodingKeys, _ value: inout Set<Fingers>) throws {
            guard c.contains(key) else { return }
            if let counts = try? c.decode(Set<Fingers>.self, forKey: key) {
                value = counts
            } else {
                value = try c.decode(Fingers?.self, forKey: key).map { [$0] } ?? []
            }
        }
        try fingers(.swipeSpaces, &swipeSpaces)
        try fingers(.missionControl, &missionControl)
        try fingers(.appExpose, &appExpose)
        try read(.notificationCenter, &notificationCenter)
        try read(.launchpad, &launchpad)
        try read(.showDesktop, &showDesktop)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trackingSpeed, forKey: .trackingSpeed)
        try c.encode(scrollSpeed, forKey: .scrollSpeed)
        try c.encode(tapToClick, forKey: .tapToClick)
        try c.encode(dragLock, forKey: .dragLock)
        try c.encode(threeFingerDrag, forKey: .threeFingerDrag)
        try c.encode(secondaryClick, forKey: .secondaryClick)
        try c.encode(naturalScrolling, forKey: .naturalScrolling)
        try c.encode(momentumScroll, forKey: .momentumScroll)
        try c.encode(pinchZoom, forKey: .pinchZoom)
        try c.encode(smartZoom, forKey: .smartZoom)
        try c.encode(lookUpForceClick, forKey: .lookUpForceClick)
        try c.encode(swipePages, forKey: .swipePages)
        // Sorted: a set's order changes from run to run, and the same settings should read the same.
        func sorted(_ counts: Set<Fingers>) -> [Fingers] { counts.sorted { $0.rawValue < $1.rawValue } }
        try c.encode(sorted(swipeSpaces), forKey: .swipeSpaces)
        try c.encode(sorted(missionControl), forKey: .missionControl)
        try c.encode(sorted(appExpose), forKey: .appExpose)
        try c.encode(notificationCenter, forKey: .notificationCenter)
        try c.encode(launchpad, forKey: .launchpad)
        try c.encode(showDesktop, forKey: .showDesktop)
    }
}
