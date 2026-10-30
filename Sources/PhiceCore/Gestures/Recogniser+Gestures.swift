import Foundation

/// What fingers landing, moving together and lifting mean, given the mode they find.
extension Recogniser {
    // MARK: Landing

    mutating func land(_ id: UInt16, at t: Double) -> [PadEvent] {
        guard let track = tracks[id] else { return [] }
        if mode == .idle {
            session = Session(start: track.startT, origin: (track.startX, track.startY))
            if lockedSince != nil {
                session.locked = true
                lockedSince = nil
            } else if let tap = lastTap, tap.fingers == 1, track.startT - tap.t <= tuning.dragWindow {
                session.tapDrag = true
            }
            mode = .pending
        }
        session.live.append(id)
        session.most = max(session.most, session.live.count)
        session.start = min(session.start, track.startT)
        if track.moved || track.verdict == .force { session.tap = false }
        guard session.live.count > 1 else {
            resetRefs(at: t)
            return []
        }
        switch mode {
        case .pending:
            session.tapDrag = false
            resetRefs(at: t)
        case .pointing, .swiping:
            mode = .pending
            resetRefs(at: t)
        case .scrolling where t - session.refT <= tuning.together:
            // The hand is still landing, one finger after another: this was never a two-finger scroll.
            mode = .pending
            resetRefs(at: t)
            return [.scroll(dx: 0, dy: 0, phase: .ended, t: t)]
        case let .dragging(_, since) where t - since >= tuning.grabDelay:
            mode = .copying
            let c = centroid()
            grab = Grab(x: c.x, y: c.y, inZone: inZone(c.x))
            return [.freeze(true)]
        default:
            break
        }
        return []
    }

    // MARK: Motion

    /// The counted fingers' common motion this frame.
    mutating func travel(_ dx: Double, _ dy: Double, at t: Double) -> [PadEvent] {
        session.acc.x += dx
        session.acc.y += dy
        if session.live.contains(where: { tracks[$0]?.moved == true }) { session.tap = false }
        let moved = dx != 0 || dy != 0
        let previous = session.lastT
        session.lastT = t
        switch mode {
        case .idle, .done:
            return []
        case .pending:
            if moved {
                if session.held.isEmpty { session.heldFrom = max(previous, t - tuning.restSample) }
                session.held.append((t, dx, dy))
            }
            let strayed = session.live.contains { (tracks[$0]?.travel ?? 0) > tuning.slop }
            return strayed ? classify(at: t) : []
        case .pointing, .dragging, .threeFingerDrag:
            return moved ? [.move(dx: dx, dy: dy, t: t)] : []
        case .copying:
            guard var grab else { return [] }
            grab.x += dx
            grab.y += dy
            grab.inZone = inZone(grab.x)
            self.grab = grab
            return []
        case .scrolling:
            guard moved else { return [] }
            session.trail.append((t, session.acc.x, session.acc.y))
            while session.trail.count > 2, session.trail[1].t < t - 2 * tuning.velocityWindow {
                session.trail.removeFirst()
            }
            return [.scroll(dx: dx, dy: dy, phase: .changed, t: t)]
        case .pinching:
            return pinch(at: t)
        case .spreading:
            return spread()
        case let .swiping(fingers):
            return swipe(fingers)
        case .edgeSwipe:
            let (dx, dy) = session.acc
            guard -dx >= tuning.swipeDistance, -dx >= abs(dy) * tuning.swipeDominance else { return [] }
            mode = .done
            return [.shortcut(.notificationCenter)]
        }
    }

    /// The fingers have moved past the slop: decide what they are doing from how many there are.
    mutating func classify(at t: Double) -> [PadEvent] {
        let (dx, dy) = session.acc
        // A still move dates where the travel set off, then each sample as it came.
        let held = session.held
        let moves: [PadEvent] = held.isEmpty ? [] : [.move(dx: 0, dy: 0, t: session.heldFrom)]
            + held.map { .move(dx: $0.dx, dy: $0.dy, t: $0.t) }
        if session.locked {
            mode = .dragging(held: session.live[0], since: session.start)
            return moves
        }
        if session.tapDrag { return grabByTap() + moves }
        let spreadChange = abs(spreadSize() - spreadSize(atRef: true))
        let translation = hypot(dx, dy)
        switch session.live.count {
        case 1:
            mode = .pointing
            return moves
        case 2:
            let startX = session.live.compactMap { tracks[$0]?.refX }.max() ?? 0
            if settings.notificationCenter, dx < 0, abs(dx) > abs(dy),
               startX >= geometry.width * (1 - tuning.edgeSwipeFraction) {
                mode = .edgeSwipe
                return travel(0, 0, at: t)
            }
            if settings.pinchZoom, spreadChange > translation {
                mode = .pinching
                session.scale = spreadSize(atRef: true)
                return pinch(at: t)
            }
            mode = .scrolling
            session.trail = [(session.refT, 0, 0), (t, dx, dy)]
            return [.scroll(dx: dx, dy: dy, phase: .began, t: t)]
        case 3 where settings.threeFingerDrag && landedTogether():
            mode = .threeFingerDrag
            return [.button(.left, down: true, clicks: 1)] + moves
        case 3:
            mode = .swiping(3)
            return swipe(3)
        default:
            if settings.launchpad || settings.showDesktop, spreadChange > translation {
                mode = .spreading
                session.scale = spreadSize(atRef: true)
                return spread()
            }
            guard session.live.count == 4 else {
                mode = .done
                return []
            }
            mode = .swiping(4)
            return swipe(4)
        }
    }

    /// Tap-to-drag takes hold: the button goes down on whatever is under the cursor.
    mutating func grabByTap() -> [PadEvent] {
        mode = .dragging(held: session.live[0], since: session.start)
        lastTap = nil
        return [.button(.left, down: true, clicks: 1)]
    }

    mutating func pinch(at t: Double) -> [PadEvent] {
        guard session.scale > 0, t - session.lastStep >= tuning.pinchInterval else { return [] }
        let size = spreadSize(), ratio = size / session.scale
        let step: Shortcut
        if ratio >= tuning.pinchStep {
            step = .zoomIn
        } else if ratio <= 1 / tuning.pinchStep {
            step = .zoomOut
        } else {
            return []
        }
        session.scale = size
        session.lastStep = t
        return [.shortcut(step)]
    }

    mutating func spread() -> [PadEvent] {
        guard session.scale > 0 else { return [] }
        let ratio = spreadSize() / session.scale
        if ratio <= 1 / tuning.spreadRatio {
            mode = .done
            return settings.launchpad ? [.shortcut(.launchpad)] : []
        }
        if ratio >= tuning.spreadRatio {
            mode = .done
            return settings.showDesktop ? [.shortcut(.showDesktop)] : []
        }
        return []
    }

    /// Three or four fingers travelling far enough along one axis: the shortcut macOS gives it.
    mutating func swipe(_ fingers: Int) -> [PadEvent] {
        let (dx, dy) = session.acc
        let long = max(abs(dx), abs(dy)), short = min(abs(dx), abs(dy))
        guard long >= tuning.swipeDistance, long >= short * tuning.swipeDominance else { return [] }
        guard let count = Fingers(rawValue: fingers) else { return [] }
        let pages = settings.swipePages == .threeFingerSwipe || settings.swipePages == .both
        let shortcut: Shortcut?
        if abs(dx) > abs(dy) {
            // Content follows the fingers: swiping left brings in what is to the right.
            if settings.swipeSpaces.contains(count) {
                shortcut = dx < 0 ? .spaceRight : .spaceLeft
            } else if fingers == 3, pages {
                shortcut = dx > 0 ? .back : .forward
            } else {
                shortcut = nil
            }
        } else if dy < 0 {
            shortcut = settings.missionControl.contains(count) ? .missionControl : nil
        } else {
            shortcut = settings.appExpose.contains(count) ? .appExpose : nil
        }
        // Nothing for this many fingers: stay open, so a finger still landing can make it one.
        guard let shortcut else { return [] }
        mode = .done
        return [.shortcut(shortcut)]
    }

    // MARK: Lifting

    mutating func lift(_ id: UInt16, at t: Double, cancelled: Bool) -> [PadEvent] {
        guard let i = session.live.firstIndex(of: id) else { return [] }
        session.live.remove(at: i)
        if cancelled {
            session.tap = false
            session.cancelled = true
        }
        if session.live.isEmpty { return end(at: t) }
        switch mode {
        case .scrolling where session.live.count < 2:
            mode = .done
            return endScroll(at: t)
        case .pinching, .spreading, .swiping, .edgeSwipe:
            mode = .done
        case .pending:
            resetRefs(at: t)
        default:
            break
        }
        return []
    }

    /// The last counted finger has lifted.
    mutating func end(at t: Double) -> [PadEvent] {
        let mode = self.mode
        self.mode = .idle
        let tapped = session.tap && t - session.start <= tuning.tapTime
        if mode == .copying {
            let inZone = grab?.inZone == true && !session.cancelled
            grab = nil
            // After a drop the Mac lets the button go itself, where it was pressed.
            if inZone { return [.drop(dropAction)] }
            return [.freeze(false), .button(.left, down: false, clicks: 1)]
        }
        if session.locked {
            if tapped { return [.button(.left, down: false, clicks: 1)] }
            lockedSince = t
            return []
        }
        switch mode {
        case .pending where tapped:
            return tap(at: t)
        case .scrolling:
            lastTap = nil
            return endScroll(at: t)
        case let .dragging(held, _) where session.pressed:
            if let track = tracks[held] {
                lastTap = Tap(t: t, x: track.x, y: track.y, fingers: 1, clicks: session.pressClicks)
            }
            return [.button(.left, down: false, clicks: session.pressClicks)]
        case .dragging:
            if settings.dragLock {
                lockedSince = t
                return []
            }
            return [.button(.left, down: false, clicks: 1)]
        case .threeFingerDrag:
            return [.button(.left, down: false, clicks: 1)]
        default:
            lastTap = nil
            return []
        }
    }

    mutating func endScroll(at t: Double) -> [PadEvent] {
        let ended = PadEvent.scroll(dx: 0, dy: 0, phase: .ended, t: t)
        guard settings.momentumScroll else { return [ended] }
        scrollEndedAt = t
        let v = liftVelocity(at: t)
        return [ended, .scrollEnded(vx: v.x, vy: v.y)]
    }

    /// Scroll velocity over the last `velocityWindow`: zero if the fingers stopped before lifting.
    func liftVelocity(at end: Double) -> (x: Double, y: Double) {
        var trail = session.trail
        let from = end - tuning.velocityWindow
        while trail.count > 1, trail[1].t <= from { trail.removeFirst() }
        guard trail.count > 1, let last = trail.last else { return (0, 0) }
        var first = trail[0]
        if first.t < from {
            let next = trail[1], f = (from - first.t) / (next.t - first.t)
            first = (from, first.x + (next.x - first.x) * f, first.y + (next.y - first.y) * f)
        }
        let dt = end - first.t
        return dt > 0 ? ((last.x - first.x) / dt, (last.y - first.y) / dt) : (0, 0)
    }

    // MARK: Taps

    /// A tap has lifted, with no added latency: click now, and count it toward the next.
    /// `tapToClick` is not consulted: a phone has no button to press, so the pad keeps tap to click
    /// on, and a Mac that has it off must not leave the phone unable to click.
    mutating func tap(at t: Double) -> [PadEvent] {
        let fingers = session.most, p = session.origin
        let previous = following(fingers: fingers, at: p, t)
        lastTap = nil
        switch fingers {
        case 1 where inCorner(p):
            return click(.right, 1)
        case 1:
            let clicks = (previous?.clicks ?? 0) + 1
            lastTap = Tap(t: t, x: p.x, y: p.y, fingers: 1, clicks: clicks)
            return click(.left, clicks)
        case 2 where settings.smartZoom && previous != nil:
            smartZoomed.toggle()
            return [.shortcut(smartZoomed ? .zoomIn : .zoomReset)]
        case 2:
            // On lift, like the Mac's own: a smart zoom, if a second tap comes, follows the click.
            lastTap = Tap(t: t, x: p.x, y: p.y, fingers: 2, clicks: 1)
            return settings.secondaryClick == .twoFingers ? click(.right, 1) : []
        case 3:
            // Look Up, as the Mac's own option has it: a fingertip barely reaches a deep press.
            return [.forceClick]
        default:
            return []
        }
    }

    /// The last click, if this one follows it closely enough in time and place to count on from it.
    func following(fingers: Int, at p: (x: Double, y: Double), _ t: Double) -> Tap? {
        lastTap.flatMap { tap in
            tap.fingers == fingers && t - tap.t <= tuning.doubleClickInterval
                && hypot(p.x - tap.x, p.y - tap.y) <= tuning.doubleClickDistance ? tap : nil
        }
    }

    func click(_ button: MouseButton, _ clicks: Int) -> [PadEvent] {
        [.button(button, down: true, clicks: clicks), .button(button, down: false, clicks: clicks)]
    }

    func inCorner(_ p: (x: Double, y: Double)) -> Bool {
        let low = p.y >= geometry.height * (1 - tuning.cornerHeight)
        switch settings.secondaryClick {
        case .bottomRight: return low && p.x >= geometry.width * (1 - tuning.cornerWidth)
        case .bottomLeft: return low && p.x <= geometry.width * tuning.cornerWidth
        case .twoFingers, .off: return false
        }
    }

    // MARK: Geometry

    /// Measure the counted fingers' travel afresh from where they are now.
    mutating func resetRefs(at t: Double) {
        for id in session.live {
            guard var track = tracks[id] else { continue }
            track.refX = track.x
            track.refY = track.y
            tracks[id] = track
        }
        session.acc = (0, 0)
        session.refT = t
        session.held = []
        session.lastT = t
    }

    func centroid() -> (x: Double, y: Double) {
        let fingers = session.live.compactMap { tracks[$0] }
        let n = Double(max(fingers.count, 1))
        return (fingers.map(\.x).reduce(0, +) / n, fingers.map(\.y).reduce(0, +) / n)
    }

    /// The counted fingers' mean distance from their centre: half the gap for two fingers.
    func spreadSize(atRef: Bool = false) -> Double {
        let points = session.live.compactMap { tracks[$0] }
            .map { atRef ? ($0.refX, $0.refY) : ($0.x, $0.y) }
        guard !points.isEmpty else { return 0 }
        let n = Double(points.count)
        let cx = points.map(\.0).reduce(0, +) / n, cy = points.map(\.1).reduce(0, +) / n
        return points.map { hypot($0.0 - cx, $0.1 - cy) }.reduce(0, +) / n
    }

    func landedTogether() -> Bool {
        let starts = session.live.compactMap { tracks[$0]?.startT }
        guard let first = starts.min(), let last = starts.max() else { return false }
        return last - first <= tuning.together
    }

    func inZone(_ x: Double) -> Bool {
        let zone = geometry.width * geometry.dropZoneFraction
        return geometry.pillSide == .left ? x <= zone : x >= geometry.width - zone
    }
}
