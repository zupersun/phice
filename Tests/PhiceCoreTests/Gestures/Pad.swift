@testable import PhiceCore

/// A scripted hand on an iPhone-sized landscape pad. Time runs in 120 Hz slots; each slot is either
/// a frame carrying every finger, as the pad sends them, or, while nothing changes, a bare tick.
/// Contact sizes behave as the iPhone 17 measured: whole steps of 12.139 pt, and 0 on lifting.
struct Pad {
    var r: Recogniser
    private(set) var slot = 0
    private(set) var frames: [TouchFrame] = []
    private(set) var events: [PadEvent] = []
    private var down: [Touch] = []
    private var nextID: UInt16 = 100

    var t: Double { Double(slot) / 120 }

    init(_ settings: TrackpadSettings = TrackpadSettings(), pill: Side = .left) {
        var geometry = Replay.defaultGeometry
        geometry.pillSide = pill
        r = Recogniser(settings: settings, geometry: geometry)
    }

    init(_ configure: (inout TrackpadSettings) -> Void) {
        var settings = TrackpadSettings()
        configure(&settings)
        self.init(settings)
    }

    // MARK: Fingers

    mutating func land(_ id: UInt16, _ x: Double, _ y: Double, r radius: Double = steps(2)) {
        land([(id, x, y)], r: radius)
    }

    /// One frame: these fingers begin, the others stay put.
    mutating func land(_ new: [(UInt16, Double, Double)], r radius: Double = steps(2)) {
        let now = Double(slot + 1) / 120
        frame { touches in
            touches += new.map {
                Touch(id: $0.0, x: $0.1, y: $0.2, radius: radius, phase: .began, t: now)
            }
        }
    }

    /// Over `count` frames each named finger travels its offset; the others stay still. With
    /// `radius`, the moving fingers' contact jumps to it halfway: a finger flattening as it slides.
    mutating func move(_ offsets: [UInt16: (Double, Double)], frames count: Int = 6,
                       radius: Double? = nil) {
        for k in 0 ..< count {
            frame { touches in
                for i in touches.indices {
                    guard let d = offsets[touches[i].id] else { continue }
                    touches[i].x += d.0 / Double(count)
                    touches[i].y += d.1 / Double(count)
                    if let radius, k >= count / 2 { touches[i].radius = radius }
                    touches[i].phase = .moved
                }
            }
        }
    }

    mutating func move(_ ids: [UInt16], _ dx: Double, _ dy: Double, frames: Int = 6,
                       radius: Double? = nil) {
        let offsets = Dictionary(uniqueKeysWithValues: ids.map { ($0, (dx, dy)) })
        move(offsets, frames: frames, radius: radius)
    }

    /// The named fingers spread from (s > 1) or close on (s < 1) their centre.
    mutating func scale(_ ids: [UInt16], by s: Double, frames: Int = 12) {
        let named = down.filter { ids.contains($0.id) }
        let cx = named.map(\.x).reduce(0, +) / Double(named.count)
        let cy = named.map(\.y).reduce(0, +) / Double(named.count)
        let offsets = named.map { ($0.id, (($0.x - cx) * (s - 1), ($0.y - cy) * (s - 1))) }
        move(Dictionary(uniqueKeysWithValues: offsets), frames: frames)
    }

    /// The contact area jumps a step in place, as pressing harder or easing off does.
    mutating func press(_ id: UInt16, to radius: Double) {
        frame { touches in
            for i in touches.indices where touches[i].id == id {
                touches[i].radius = radius
                touches[i].phase = .moved
            }
        }
    }

    /// Fingers stay down and still; the pad keeps sending frames.
    mutating func hold(_ seconds: Double) {
        for _ in 0 ..< Int((seconds * 120).rounded()) { frame { _ in } }
    }

    /// Nothing changes and no frames arrive, only the 120 Hz ticks.
    mutating func wait(_ seconds: Double) {
        for _ in 0 ..< Int((seconds * 120).rounded()) {
            slot += 1
            events += r.tick(now: t)
        }
    }

    mutating func lift(_ ids: UInt16...) { end(ids, as: .ended) }

    /// The system took the touches (a call, a gesture), so they did not really lift.
    mutating func cancel(_ ids: UInt16...) { end(ids, as: .cancelled) }

    /// The finger drops out of later frames without ever being reported as lifted.
    mutating func vanish(_ id: UInt16) { down.removeAll { $0.id == id } }

    // MARK: Whole gestures

    mutating func tap(_ x: Double = 400, _ y: Double = 200) { tap(fingers: 1, x, y) }

    mutating func tap(fingers: Int, _ x: Double = 400, _ y: Double = 200) {
        let ids = (0 ..< fingers).map { _ in nextID += 1; return nextID }
        land(ids.enumerated().map { ($1, x + Double($0) * 40, y + Double($0 % 2) * 6) })
        hold(0.05)
        end(ids, as: .ended)
    }

    // MARK: What came out

    mutating func clear() { events = [] }

    /// Everything but motion: clicks, shortcuts, force clicks, freezes, drops, momentum stops.
    var actions: [PadEvent] { events.filter(isAction) }

    /// Total pointer travel.
    var travel: (dx: Double, dy: Double) {
        events.reduce((0, 0)) { sum, event in
            if case let .move(dx, dy, _) = event { return (sum.0 + dx, sum.1 + dy) }
            return sum
        }
    }

    /// Total scroll travel.
    var scrolled: (dx: Double, dy: Double) {
        events.reduce((0, 0)) { sum, event in
            if case let .scroll(dx, dy, _, _) = event { return (sum.0 + dx, sum.1 + dy) }
            return sum
        }
    }

    var scrollPhases: [ScrollPhase] {
        events.compactMap { if case let .scroll(_, _, phase, _) = $0 { phase } else { nil } }
    }

    var scrollEnds: [(vx: Double, vy: Double)] {
        events.compactMap { if case let .scrollEnded(vx, vy) = $0 { (vx, vy) } else { nil } }
    }

    // MARK: Plumbing

    private mutating func end(_ ids: [UInt16], as phase: Touch.Phase) {
        frame { touches in
            for i in touches.indices where ids.contains(touches[i].id) {
                touches[i].phase = phase
                touches[i].radius = 0
            }
        }
    }

    /// Advances one slot and sends a frame once `change` has updated the fingers.
    private mutating func frame(_ change: (inout [Touch]) -> Void) {
        slot += 1
        for i in down.indices {
            down[i].phase = .stationary
            down[i].t = t
        }
        change(&down)
        let frame = TouchFrame(t: t, touches: down)
        frames.append(frame)
        events += r.feed(frame)
        down.removeAll { $0.phase == .ended || $0.phase == .cancelled }
    }
}

func click(_ button: MouseButton = .left, _ clicks: Int = 1) -> [PadEvent] {
    [.button(button, down: true, clicks: clicks), .button(button, down: false, clicks: clicks)]
}

let press = PadEvent.button(.left, down: true, clicks: 1)
let release = PadEvent.button(.left, down: false, clicks: 1)

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

/// A contact size the iPhone 17 can report: whole steps of 12.139 pt.
func steps(_ n: Double) -> Double { n * 12.139 }

func isAction(_ event: PadEvent) -> Bool {
    switch event {
    case .move, .scroll, .scrollEnded: false
    default: true
    }
}
