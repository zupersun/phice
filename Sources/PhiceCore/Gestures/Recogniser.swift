import Foundation

/// Which edge of the pad the pill sits on. The drop zone is the fifth of the pad on that side.
public enum Side: String, Codable, Sendable {
    case left, right
}

public struct PadGeometry: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var pillSide: Side
    public var dropZoneFraction: Double

    public init(width: Double, height: Double, pillSide: Side = .left, dropZoneFraction: Double = 0.2) {
        self.width = width
        self.height = height
        self.pillSide = pillSide
        self.dropZoneFraction = dropZoneFraction
    }
}

/// The copy gesture in progress: where the held item's bead is, and whether it is over the drop zone.
public struct Grab: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var inZone: Bool

    public init(x: Double, y: Double, inZone: Bool) {
        self.x = x
        self.y = y
        self.inZone = inZone
    }
}

/// Turns raw touches into what they mean. Pure: time comes only from frames and `tick(now:)`.
/// Touches that begin on the pill never reach it; the pill's own view owns those.
///
/// Each frame runs in a fixed order: timeouts, then each finger (admitted, followed, judged),
/// then landings, the fingers' common motion, force, and lifts. The gestures themselves are in
/// `Recogniser+Gestures.swift`.
public struct Recogniser: Sendable {
    public var settings: TrackpadSettings
    public var geometry: PadGeometry
    public var dropAction: DropAction = .copy
    /// Every threshold the gestures use.
    public var tuning = GestureTuning()
    public private(set) var verdicts: [UInt16: TouchVerdict] = [:]
    public internal(set) var grab: Grab?

    var tracks: [UInt16: Track] = [:]
    var mode = Mode.idle
    var session = Session()
    var lastTap: Tap?
    /// When drag lock last kept the button down through a lift; nil when it holds nothing.
    var lockedSince: Double?
    var scrollEndedAt: Double?
    var smartZoomed = false
    /// When a two-finger tap's right click was held back for a possible smart zoom.
    var secondaryAt: Double?

    public init(settings: TrackpadSettings, geometry: PadGeometry) {
        self.settings = settings
        self.geometry = geometry
    }

    public mutating func feed(_ frame: TouchFrame) -> [PadEvent] {
        let t = frame.t
        var out = heldSecondary(before: [], at: t) + advance(to: t)
        let present = Set(frame.touches.map(\.id))
        for id in tracks.keys.sorted() where !present.contains(id) { out += forget(id, at: t) }

        var landed: [UInt16] = [], lifted: [(id: UInt16, cancelled: Bool)] = []
        var sum = (x: 0.0, y: 0.0), movers = 0.0
        for touch in frame.touches {
            guard touch.phase != .began, var track = tracks[touch.id] else {
                if tracks[touch.id] != nil { out += forget(touch.id, at: t) }
                out += stopMomentum(at: t)
                let track = admit(touch, at: t)
                tracks[touch.id] = track
                if track.status == .live { landed.append(touch.id) }
                continue
            }
            let was = (x: track.x, y: track.y, status: track.status)
            track.follow(touch, tuning: tuning)
            judge(&track, at: t)
            switch (was.status, track.status) {
            case (.live, .live):
                sum.x += track.x - was.x
                sum.y += track.y - was.y
                movers += 1
            case (.live, .rejected): lifted.append((touch.id, true))
            case (.waiting, .live): landed.append(touch.id)
            default: break
            }
            if touch.phase == .ended || touch.phase == .cancelled {
                if track.status == .live {
                    lifted.append((touch.id, touch.phase == .cancelled))
                } else if track.status == .waiting, mode == .idle, touch.phase == .ended {
                    // A quick tap by a wide finger, lifted before it could be judged a hand.
                    track.status = .live
                    landed.append(touch.id)
                    lifted.append((touch.id, false))
                }
            }
            tracks[touch.id] = track
        }
        for id in landed { out += land(id, at: t) }
        if movers > 0 { out += travel(sum.x / movers, sum.y / movers, at: t) }
        out += pressure(at: t)
        for lift in lifted { out += self.lift(lift.id, at: t, cancelled: lift.cancelled) }
        for touch in frame.touches where touch.phase == .ended || touch.phase == .cancelled {
            tracks[touch.id] = nil
        }
        publish()
        return heldSecondary(before: out, at: t)
    }

    /// Time-based transitions: tap-to-drag hold, drag lock, baselines, firm holds, resting hands.
    public mutating func tick(now: Double) -> [PadEvent] {
        let out = advance(to: now)
        publish()
        return heldSecondary(before: out, at: now)
    }

    /// A two-finger tap's right click waits while a second tap could still make it a smart zoom,
    /// but goes out ahead of anything else that happens, so it lands where the tap was.
    mutating func heldSecondary(before out: [PadEvent], at t: Double) -> [PadEvent] {
        guard let since = secondaryAt, !out.isEmpty || t - since > tuning.doubleClickInterval
        else { return out }
        secondaryAt = nil
        return click(.right, 1) + out
    }

    // MARK: Time

    mutating func advance(to now: Double) -> [PadEvent] {
        var out: [PadEvent] = []
        for id in tracks.keys.sorted() {
            guard var track = tracks[id] else { continue }
            let was = track.status
            judge(&track, at: now)
            tracks[id] = track
            if was == .waiting, track.status == .live { out += land(id, at: now) }
            if was == .live, track.status == .rejected { out += lift(id, at: now, cancelled: true) }
        }
        out += pressure(at: now)
        if mode == .pending, session.tapDrag, session.live.count == 1,
           now - session.start >= tuning.dragHold {
            out += grabByTap()
        }
        if mode == .idle, let since = lockedSince, now - since >= tuning.dragLockTimeout {
            lockedSince = nil
            out.append(.button(.left, down: false, clicks: 1))
        }
        return out
    }

    // MARK: Fingers

    /// Contact size in whole steps of the device's quantum.
    func steps(_ radius: Double) -> Int {
        let quantum = tuning.force.quantum
        return quantum > 0 ? Int((radius / quantum).rounded()) : 0
    }

    /// A new finger: a palm is rejected outright, one at a resting hand's size waits to be judged.
    func admit(_ touch: Touch, at t: Double) -> Track {
        let force = tuning.force, size = steps(touch.radius)
        let status: Track.Status = size >= force.palmSteps ? .rejected
            : size >= force.restingSteps ? .waiting : .live
        return Track(touch, at: t, status: status)
    }

    /// Reads the resting size once the touch-down ramp is over, rejects a palm at once and a
    /// resting hand once it has stayed wide and still, and lets a waiting touch in once it moves
    /// or shrinks to a finger's size. A touch that has force-clicked is a finger pressing, not a hand.
    mutating func judge(_ track: inout Track, at t: Double) {
        let force = tuning.force, size = steps(track.radius)
        if track.baseline == nil, t - track.startT >= force.baselineDelay {
            track.baseline = size
            track.baseX = track.x
            track.baseY = track.y
        }
        if size < force.restingSteps {
            track.wideSince = nil
        } else if track.wideSince == nil
                    || hypot(track.x - track.wideX, track.y - track.wideY) > force.stillDistance {
            track.wideSince = t
            track.wideX = track.x
            track.wideY = track.y
        }
        guard track.status != .rejected else { return }
        let resting = track.verdict != .force
            && track.wideSince.map { t - $0 >= force.restingHold } == true
        if size >= force.palmSteps || resting {
            track.reject()
        } else if track.status == .waiting, track.moved || size < force.restingSteps {
            track.status = .live
        }
    }

    /// A lone, still finger pressing: it rose a step past rest to `forceSteps`, or it landed there
    /// and held. Fires once, re-armed by returning to rest; never during a move or scroll.
    mutating func pressure(at t: Double) -> [PadEvent] {
        guard settings.lookUpForceClick, session.live.count == 1, mode == .pending,
              let id = session.live.first, var track = tracks[id], let baseline = track.baseline
        else { return [] }
        let force = tuning.force, size = steps(track.radius)
        let firm = baseline >= force.forceSteps
        if !track.armed, !firm, size <= baseline { track.armed = true }
        let still = hypot(track.x - track.baseX, track.y - track.baseY) < force.stillDistance
        // Four steps and up is a hand's size, judged as one, not a press.
        let target = max(baseline + (firm ? 0 : 1), force.forceSteps)
        let held = !firm || t - track.startT >= force.firmHold
        let pressed = size >= target && size < force.restingSteps && held
        guard track.armed, still, pressed else {
            tracks[id] = track
            return []
        }
        track.armed = false
        track.verdict = .force
        tracks[id] = track
        session.tap = false
        return [.forceClick]
    }

    /// A finger gone without a proper lift: it vanished from the frames, or its id began again.
    mutating func forget(_ id: UInt16, at t: Double) -> [PadEvent] {
        let wasLive = tracks[id]?.status == .live
        tracks[id] = nil
        return wasLive ? lift(id, at: t, cancelled: true) : []
    }

    mutating func stopMomentum(at t: Double) -> [PadEvent] {
        guard let since = scrollEndedAt else { return [] }
        scrollEndedAt = nil
        return t - since <= tuning.momentumWindow ? [.momentumStop] : []
    }

    mutating func publish() {
        verdicts = tracks.mapValues(\.verdict)
    }
}
