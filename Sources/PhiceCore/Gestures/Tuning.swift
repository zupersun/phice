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
    /// Tap-to-drag arms only for a touch landing this soon after a tap lifts: a double tap, not a
    /// click followed by the next stroke. Apple documents no value; this is libinput's tap timeout.
    public var dragWindow = 0.18
    /// An armed touch that holds this long without moving grabs.
    public var dragHold = 0.15
    /// Drag lock lets go by itself after this long with no finger down.
    public var dragLockTimeout = 3.0
    /// Fingers landing within this of each other landed as one hand: three-finger drag needs it,
    /// and a finger this soon after the one before still turns a young scroll into a swipe.
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
    public var force = ForceTuning()

    public init() {}
}

/// Force press and resting-hand rules, read from `UITouch.majorRadius`. It is quantised, so sizes
/// are counted in whole steps of `quantum`. Measured on an iPhone 17 (103 touches, 5,121 samples):
/// an ordinary finger is 2 steps (a few land at 1 and ramp to 2 within 50 ms, a few quick taps land
/// at 3), a hard press rises from 1–2 to 3, a flat thumb runs 2→4→5→6, and a finger can flatten
/// 1→3 while it slides. Relaxing is too coarse to read, and lifting reports 0.
public struct ForceTuning: Sendable, Equatable {
    /// Points per step: 12.139 on an iPhone 17. On other devices the pad sets it to
    /// `2 × majorRadiusTolerance`.
    public var quantum = 12.139
    /// The resting size is read once a finger has stayed put this long: after landing, past the
    /// touch-down ramp, or after pointing, once it stops on its target.
    public var baselineDelay = 0.08
    /// A pointing finger drifting less than this over `baselineDelay` has stopped.
    public var restJitter = 3.0
    /// A force press reaches at least this many steps, and at least one more than at rest.
    public var forceSteps = 3
    /// A touch already at `forceSteps` when its baseline is read, still there this long after landing,
    /// pressed hard from the start. One that lifts sooner was a firm tap.
    public var firmHold = 0.25
    /// Farther than this from where it rested and the touch is moving, not pressing; it needs a new
    /// rest before it can press again.
    public var stillDistance = 10.0
    /// This many steps held still for `restingHold` is a resting hand. A firm finger is one step less.
    public var restingSteps = 4
    public var restingHold = 0.15
    /// This many steps is a palm or a flat thumb, at once.
    public var palmSteps = 5

    public init() {}
}
