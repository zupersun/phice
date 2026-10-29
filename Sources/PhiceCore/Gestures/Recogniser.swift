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

    public init(settings: TrackpadSettings, geometry: PadGeometry) {
        self.settings = settings
        self.geometry = geometry
    }

    public mutating func feed(_ frame: TouchFrame) -> [PadEvent] {
        let t = frame.t
        var out = advance(to: t)
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
            track.follow(touch, at: t, tuning: tuning)
            judge(&track, at: t, out: &out)
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
                    // A quick tap by a wide finger, lifted before it could be judged.
                    track.status = .live
                    landed.append(touch.id)
                    lifted.append((touch.id, false))
                }
            }
            tracks[touch.id] = track
        }
        for id in landed { out += land(id, at: t) }
        if movers > 0 { out += travel(sum.x / movers, sum.y / movers, at: t) }
        out += pressure()
        for lift in lifted { out += self.lift(lift.id, at: t, cancelled: lift.cancelled) }
        for touch in frame.touches where touch.phase == .ended || touch.phase == .cancelled {
            tracks[touch.id] = nil
        }
        publish()
        return out
    }

    /// Time-based transitions: tap timeouts, tap-to-drag grace, force press settling.
    public mutating func tick(now: Double) -> [PadEvent] {
        let out = advance(to: now)
        publish()
        return out
    }

    // MARK: Time

    mutating func advance(to now: Double) -> [PadEvent] {
        var out: [PadEvent] = []
        for id in tracks.keys.sorted() where tracks[id]?.status == .waiting {
            guard var track = tracks[id] else { continue }
            judge(&track, at: now, out: &out)
            tracks[id] = track
            if track.status == .live { out += land(id, at: now) }
        }
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

    /// A new finger: a palm is rejected outright; a wide one, or one gripping an edge, waits.
    func admit(_ touch: Touch, at t: Double) -> Track {
        let force = tuning.force, margin = tuning.edgeMargin
        let nearEdge = touch.x < margin || touch.y < margin
            || touch.x > geometry.width - margin || touch.y > geometry.height - margin
        let wide = touch.radius >= force.wideRadius
        let status: Track.Status = touch.radius >= force.palmRadius ? .rejected
            : wide || (nearEdge && touch.radius >= force.edgeWideRadius) ? .waiting : .live
        return Track(touch, at: t, status: status, landedWide: wide)
    }

    /// Rejects a palm at any moment, and settles a waiting touch: moving makes it a finger,
    /// relaxing clearly after landing wide is a force press, staying wide and still is a hand.
    mutating func judge(_ track: inout Track, at t: Double, out: inout [PadEvent]) {
        let force = tuning.force
        if track.status != .rejected, track.radius >= force.palmRadius { track.reject() }
        guard track.status == .waiting else { return }
        if track.moved {
            track.status = .live
        } else if track.landedWide, track.radius <= track.widest * force.relaxRatio {
            track.status = .live
            // Only a lone finger force-presses.
            if settings.lookUpForceClick, mode == .idle {
                track.verdict = .force
                track.armed = false
                out.append(.forceClick)
            }
        } else if t - track.startT >= force.settle {
            let wide = track.landedWide ? force.wideRadius : force.edgeWideRadius
            if track.radius >= wide { track.reject() } else { track.status = .live }
        }
    }

    /// A lone finger pressing harder: a force click on the rise, once, re-armed by easing back.
    mutating func pressure() -> [PadEvent] {
        guard settings.lookUpForceClick, session.live.count == 1, mode == .pending || mode == .pointing,
              let id = session.live.first, var track = tracks[id], let rest = track.rest
        else { return [] }
        let force = tuning.force
        var out: [PadEvent] = []
        if track.armed, track.radius >= rest * force.riseRatio {
            track.armed = false
            track.verdict = .force
            session.tap = false
            out.append(.forceClick)
        } else if !track.armed, track.radius <= rest * force.rearmRatio {
            track.armed = true
        }
        tracks[id] = track
        return out
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
