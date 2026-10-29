/// Turns the phone's messages into posted input: Apple's curves, local momentum, the copy-drop and
/// paste sequences, and the silence timeout that releases a held button. Pure: time is passed in.
///
/// Every number from the phone is validated here before it reaches a CGEvent: non-finite values
/// drop the event, deltas are clamped to `maxDelta`, intervals to `0...maxInterval`, click counts to
/// 1...3 and the tracking and scroll speeds to Apple's 0...3.
///
/// Scroll deltas are posted in CGEvent's convention: positive `dy` scrolls toward the top (the
/// content moves down, as a mouse wheel rolled away from you does) and positive `dx` toward the
/// left. The poster passes them straight to wheel 1 and wheel 2. macOS never applies Natural
/// scrolling to posted events, so the direction setting is applied here: with it, content follows
/// the fingers, and fingers moving down (positive finger `dy`) post a positive `dy`.
public final class MacDriver {
    /// After this long without any message (heartbeats included) a held button is released and
    /// momentum stops, so a phone that vanishes mid-drag never leaves the mouse button down.
    public static let silenceTimeout = 0.5
    /// Larger deltas, in pad points per event, are clamped.
    public static let maxDelta = 500.0
    /// Longer gaps between event stamps count as this long; the first event of a session too.
    public static let maxInterval = 0.1
    /// Lift speeds, in pad points per second, are clamped to this; a hard flick is ~5000.
    static let maxLiftSpeed = 10_000.0

    private let poster: EventPoster
    private let curves: [AccelCurve]
    private let scrollCurves: [AccelCurve]
    private var settings: TrackpadSettings
    private var pointer: PointerAcceleration
    private var scroller: ScrollAcceleration

    private var enabled = true
    private var lastHeard: Double?
    private var lastMove: Double?
    private var lastScroll: Double?
    /// Held buttons and the click count each went down with, which its release repeats.
    private var held: [MouseButton: Int] = [:]
    private var pressPoint = (x: 0.0, y: 0.0)
    private var frozen = false
    /// A freeze happened during this press, so its release goes back to the press point.
    private var releaseAtPress = false
    private var momentum: Momentum?
    private var momentumBegun = false
    private var lastMomentumTick = 0.0

    /// `settings.scrollSpeed` (`HIDTrackpadScrollAcceleration`, 0...3) picks the scroll curve.
    public init(poster: EventPoster, settings: TrackpadSettings, curves: [AccelCurve],
                scrollCurves: [AccelCurve]) {
        self.poster = poster
        self.curves = curves
        self.scrollCurves = scrollCurves
        self.settings = settings
        let defaults = TrackpadSettings()
        self.settings.trackingSpeed = Self.speed(settings.trackingSpeed, else: defaults.trackingSpeed)
        self.settings.scrollSpeed = Self.speed(settings.scrollSpeed, else: defaults.scrollSpeed)
        pointer = PointerAcceleration(curves: curves, trackingSpeed: self.settings.trackingSpeed)
        scroller = ScrollAcceleration(curves: scrollCurves, speed: self.settings.scrollSpeed)
    }

    /// Returns any replies for the phone (`dropResult`).
    public func handle(_ message: PhoneToMac, now: Double) -> [MacToPhone] {
        lastHeard = now
        switch message {
        case let .events(events):
            guard enabled else { return [] }
            return events.flatMap { handle($0, now: now) }
        case let .settings(new):
            apply(new)
        case let .enabled(on):
            if !on { releaseAll(); stopMomentum() }
            enabled = on
        case .hello, .heartbeat, .record, .frames, .forget:
            break
        }
        return []
    }

    /// Momentum steps and the silence timeout.
    public func tick(now: Double) {
        if let lastHeard, now - lastHeard > Self.silenceTimeout {
            releaseAll()
            stopMomentum()
        }
        guard momentum != nil else { return }
        let dt = Self.interval(now - lastMomentumTick)
        lastMomentumTick = now
        guard dt > 0 else { return }
        guard let step = momentum?.step(dt: dt) else { return stopMomentum() }
        postScroll(scroller.apply(dx: step.dx, dy: step.dy, dt: dt), phase: nil,
                   momentum: momentumBegun ? .continue : .begin)
        momentumBegun = true
    }

    private func handle(_ event: PadEvent, now: Double) -> [MacToPhone] {
        switch event {
        case let .move(dx, dy, t):
            guard let d = Self.delta(dx, dy), t.isFinite else { break }
            let dt = Self.interval(lastMove.map { t - $0 } ?? Self.maxInterval)
            lastMove = t
            guard !frozen else { break }
            let out = pointer.apply(dx: d.dx, dy: d.dy, dt: dt)
            poster.move(dx: out.dx, dy: out.dy, dragging: dragging)
        case let .button(button, down, clicks):
            let clicks = min(max(clicks, 1), 3)
            if down { press(button, clicks: clicks) } else { release(button, clicks: clicks) }
        case let .scroll(dx, dy, phase, t):
            guard let d = Self.delta(dx, dy), t.isFinite else { break }
            stopMomentum()
            if phase == .began { scroller.reset(); lastScroll = nil }
            let dt = lastScroll.map { Self.interval(t - $0) }
            lastScroll = t
            postScroll(scroller.apply(dx: d.dx, dy: d.dy, dt: dt), phase: phase, momentum: nil)
        case let .scrollEnded(vx, vy):
            guard settings.momentumScroll, vx.isFinite, vy.isFinite else { break }
            let limit = Self.maxLiftSpeed
            momentum = Momentum(vx: min(max(vx, -limit), limit), vy: min(max(vy, -limit), limit))
            momentumBegun = false
            lastMomentumTick = now
        case .momentumStop:
            stopMomentum()
        case let .shortcut(shortcut):
            poster.shortcut(shortcut)
        case .forceClick:
            poster.forceClick()
        case let .freeze(on):
            frozen = on
            if on, !held.isEmpty { releaseAtPress = true }
        case let .drop(action):
            let ok = poster.perform(action)
            if let clicks = held[.left] {
                releaseAtPress = true
                release(.left, clicks: clicks)
            }
            return [.dropResult(ok: ok)]
        case let .paste(itemID):
            poster.button(.left, down: true, clicks: 1)
            poster.button(.left, down: false, clicks: 1)
            poster.paste(itemID: itemID)
        }
        return []
    }

    private var dragging: MouseButton? { held[.left] != nil ? .left : held.keys.first }

    private func press(_ button: MouseButton, clicks: Int) {
        guard held[button] == nil else { return }
        if held.isEmpty { pressPoint = poster.cursor }
        held[button] = clicks
        poster.button(button, down: true, clicks: clicks)
    }

    /// A release the phone sends after the Mac already released (drop, silence) is not posted again.
    private func release(_ button: MouseButton, clicks: Int) {
        guard held[button] != nil else { return }
        // A cancelled copy must not drop a dragged file wherever the frozen cursor ended up.
        if releaseAtPress { poster.moveTo(x: pressPoint.x, y: pressPoint.y, dragging: button) }
        held[button] = nil
        poster.button(button, down: false, clicks: clicks)
        if held.isEmpty { releaseAtPress = false }
    }

    private func releaseAll() {
        for button in [MouseButton.left, .right] {
            if let clicks = held[button] { release(button, clicks: clicks) }
        }
        frozen = false
    }

    private func stopMomentum() {
        if momentum != nil, momentumBegun { poster.scroll(dx: 0, dy: 0, phase: nil, momentum: .end) }
        momentum = nil
        momentumBegun = false
    }

    private func postScroll(_ fingers: (dx: Double, dy: Double), phase: ScrollPhase?,
                            momentum: MomentumPhase?) {
        let sign = settings.naturalScrolling ? 1.0 : -1.0
        poster.scroll(dx: sign * fingers.dx, dy: sign * fingers.dy, phase: phase, momentum: momentum)
    }

    private func apply(_ new: TrackpadSettings) {
        var new = new
        new.trackingSpeed = Self.speed(new.trackingSpeed, else: settings.trackingSpeed)
        new.scrollSpeed = Self.speed(new.scrollSpeed, else: settings.scrollSpeed)
        if new.trackingSpeed != settings.trackingSpeed {
            pointer = PointerAcceleration(curves: curves, trackingSpeed: new.trackingSpeed)
        }
        if new.scrollSpeed != settings.scrollSpeed {
            scroller = ScrollAcceleration(curves: scrollCurves, speed: new.scrollSpeed)
        }
        if !new.momentumScroll { stopMomentum() }
        settings = new
    }

    private static func delta(_ dx: Double, _ dy: Double) -> (dx: Double, dy: Double)? {
        guard dx.isFinite, dy.isFinite else { return nil }
        return (min(max(dx, -maxDelta), maxDelta), min(max(dy, -maxDelta), maxDelta))
    }

    private static func interval(_ dt: Double) -> Double { min(max(dt, 0), maxInterval) }

    private static func speed(_ speed: Double, else fallback: Double) -> Double {
        speed.isFinite ? min(max(speed, 0), 3) : fallback
    }
}
