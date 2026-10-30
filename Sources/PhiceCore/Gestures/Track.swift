import Foundation

/// One finger as the recogniser follows it from landing to lifting.
struct Track: Sendable {
    enum Status: Sendable {
        /// Counted in gestures.
        case live
        /// Landed at a resting hand's size; left out until it moves, shrinks or settles.
        case waiting
        /// A palm or a resting hand: left out until it lifts.
        case rejected
    }

    let startX: Double, startY: Double, startT: Double
    var x: Double, y: Double, radius: Double
    /// Where the gesture in progress measures this finger's travel from.
    var refX: Double, refY: Double
    /// Strayed past the slop since landing, so it is not part of a tap.
    var moved = false
    var status: Status
    /// Where it last came to rest and since when, and its contact size there in steps once it has
    /// stayed `baselineDelay`. Force press reads against that.
    var baseX: Double, baseY: Double, baseT: Double
    var baseline: Int?
    /// It is still resting where it landed, so a firm landing held still can force-click.
    var landing = true
    /// The size it pressed at, while the press holds the button down; and since when its contact
    /// has eased a step, for the release.
    var pressedAt: Int?
    var easedSince: Double?
    /// Joined a three-finger hand as its thumb: wide, but not a resting hand.
    var thumb = false
    /// Since when it has been at a resting hand's size and still, and where.
    var wideSince: Double?
    var wideX = 0.0, wideY = 0.0
    var verdict = TouchVerdict.live

    init(_ touch: Touch, at t: Double, status: Status) {
        startX = touch.x
        startY = touch.y
        startT = t
        x = touch.x
        y = touch.y
        radius = touch.radius
        refX = touch.x
        refY = touch.y
        baseX = touch.x
        baseY = touch.y
        baseT = t
        self.status = status
        if status == .rejected { verdict = .rejected }
    }

    var travel: Double { hypot(x - refX, y - refY) }

    mutating func follow(_ touch: Touch, tuning: GestureTuning) {
        x = touch.x
        y = touch.y
        if hypot(x - startX, y - startY) > tuning.slop { moved = true }
        // A lift reports radius 0: the finger leaving, not shrinking.
        if touch.phase != .ended, touch.phase != .cancelled { radius = touch.radius }
    }

    mutating func reject() {
        status = .rejected
        verdict = .rejected
    }
}

/// What the fingers on the pad are doing together.
enum Mode: Equatable, Sendable {
    case idle
    /// Fingers down, nothing decided: could still be a tap.
    case pending
    case pointing
    case scrolling
    case pinching
    /// Thumb and three fingers closing or opening.
    case spreading
    case swiping(Int)
    /// Two fingers coming in from the right edge.
    case edgeSwipe
    /// Left button held by tap-to-drag (or drag lock); `since` is when the held finger landed.
    case dragging(held: UInt16, since: Double)
    /// The copy gesture: button held, cursor frozen, the item riding between the fingers.
    case copying
    case threeFingerDrag
    /// The gesture has fired; nothing more until every finger lifts.
    case done
}

/// One hand on the pad: from the first counted finger landing until the last one lifts.
struct Session: Sendable {
    var start = 0.0
    var origin = (x: 0.0, y: 0.0)
    /// Counted fingers down, in landing order.
    var live: [UInt16] = []
    var most = 0
    var tap = true
    /// The system took a finger: whatever this was, it does not complete.
    var cancelled = false
    /// Landed soon after a tap: holding or moving grabs.
    var tapDrag = false
    /// Landed while drag lock held the button.
    var locked = false
    /// A press holds the button down, with the click count it went down with.
    var pressed = false
    var pressClicks = 1
    /// Common travel of the fingers since `refT`, when their references were last set.
    var acc = (x: 0.0, y: 0.0)
    var refT = 0.0
    /// That travel sample by sample while undecided, and when the first sample set off: it goes to
    /// the Mac as the moves it was, not as one lump the Mac would read as slow.
    var held: [(t: Double, dx: Double, dy: Double)] = []
    var heldFrom = 0.0
    /// The last frame the fingers were seen in.
    var lastT = 0.0
    /// Pinch or spread size at the last step.
    var scale = 0.0
    var lastStep = -Double.infinity
    /// Scroll position over time, for the lift velocity.
    var trail: [(t: Double, x: Double, y: Double)] = []
}

/// A recent tap, for double clicks, tap-to-drag and smart zoom.
struct Tap: Sendable {
    var t, x, y: Double
    var fingers, clicks: Int
}
