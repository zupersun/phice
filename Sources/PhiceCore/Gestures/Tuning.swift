/// Every number the recogniser decides by, in pad points and seconds; nothing else in Gestures
/// hardcodes one. First guesses, to be tuned against recordings from the phone with `phice-replay`.
public struct GestureTuning: Sendable, Equatable {
    /// A finger that strays farther than this from where it landed is moving, not tapping.
    public var slop = 8.0
    /// A tap lifts within this long of the first finger landing.
    public var tapTime = 0.3
    /// Taps this close in time and on the pad count up into double and triple clicks (macOS: 0.5 s).
    public var doubleClickInterval = 0.5
    public var doubleClickDistance = 40.0
    /// Tap-to-drag: a touch soon after a tap that holds this long without moving grabs.
    public var dragHold = 0.15
    /// Drag lock lets go by itself after this long with no finger down.
    public var dragLockTimeout = 3.0
    /// Fingers landing within this of each other landed as one hand: three-finger drag needs it,
    /// and a third finger this late still turns a two-finger scroll into a three-finger gesture.
    public var together = 0.1
    /// The copy gesture's second finger lands at least this long after the held one.
    public var grabDelay = 0.15
    /// Scroll lift velocity is measured over this last stretch before the lift.
    public var velocityWindow = 0.06
    /// A finger landing this soon after a scroll's lift stops the Mac's momentum.
    public var momentumWindow = 3.0
    /// Three- and four-finger swipes fire after this much travel along an axis that leads the
    /// other by `swipeDominance`; so does the swipe in from the edge for Notification Centre.
    public var swipeDistance = 60.0
    public var swipeDominance = 1.5
    /// Two fingers starting within this fraction of the width from the right edge swipe in.
    public var edgeSwipeFraction = 0.04
    /// Each pinch step needs the fingers' spread to change by this ratio, once per `pinchInterval`.
    public var pinchStep = 1.25
    public var pinchInterval = 0.2
    /// Thumb and three fingers closing or opening by this ratio: Launchpad or Show Desktop.
    public var spreadRatio = 1.35
    /// The corner-click regions, as fractions of the pad's width and height.
    public var cornerWidth = 0.25
    public var cornerHeight = 0.3
    /// Touches landing this close to an edge may be the hand holding the phone.
    public var edgeMargin = 20.0
    public var force = ForceTuning()

    public init() {}
}

/// Force press and resting-hand thresholds, all read from `UITouch.majorRadius` in points.
/// PROVISIONAL: guesses until the touch probe's measurements from the iPhone arrive.
public struct ForceTuning: Sendable, Equatable {
    /// A finger's resting size is its mean radius over this long after it lands.
    public var baselineWindow = 0.04
    /// Rising past resting size × this is a force press.
    public var riseRatio = 1.4
    /// It can fire again only after falling back under resting size × this.
    public var rearmRatio = 1.15
    /// A touch landing at least this wide waits `settle` to see whether it relaxes (a force
    /// press) or stays wide and still (a resting thumb).
    public var wideRadius = 38.0
    /// Near an edge, this wide and still for `settle` is the hand holding the phone.
    public var edgeWideRadius = 28.0
    public var settle = 0.2
    /// Relaxing clearly: shrinking under the widest it has been × this.
    public var relaxRatio = 0.8
    /// Wider than this is a palm, wherever and whenever.
    public var palmRadius = 55.0

    public init() {}
}
