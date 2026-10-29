import PhiceCore

/// One coalesced sample of one finger, lifted off `UITouch` so frame building can be tested.
struct TouchSample: Equatable {
    /// The `UITouch`'s address: stable while that finger is down, reusable after it lifts.
    var key: UInt
    var x: Double
    var y: Double
    var radius: Double
    var phase: Touch.Phase
    /// Seconds since boot (`UITouch.timestamp`), the clock `tick(now:)` is given too.
    var t: Double
    /// `UITouch.majorRadiusTolerance`; 0 when unknown.
    var tolerance = 0.0
}

/// Turns samples into `TouchFrame`s: one per instant the digitizer reported, holding every finger
/// still down, each with an id that stays the same from landing to lift.
struct FrameBuilder {
    /// Fingers down after the last frame, by id.
    private(set) var live: [UInt16: Touch] = [:]
    private var fingers: [UInt: (id: UInt16, t: Double)] = [:]
    private var nextID: UInt16 = 0

    mutating func frames(from samples: [TouchSample]) -> [TouchFrame] {
        // The digitizer scans every finger at once, so one instant is one shared timestamp.
        let samples = samples.sorted { $0.t < $1.t }
        var frames: [TouchFrame] = []
        var sampled: Set<UInt16> = []
        for (i, sample) in samples.enumerated() {
            if let id = take(sample) { sampled.insert(id) }
            let instantEnds = i == samples.count - 1 || samples[i + 1].t != sample.t
            guard instantEnds, !sampled.isEmpty else { continue }
            frames.append(frame(at: sample.t, sampled: sampled))
            sampled = []
        }
        return frames
    }

    /// Records one sample; nil when it was built before or its finger was never seen landing.
    private mutating func take(_ sample: TouchSample) -> UInt16? {
        if sample.phase == .began {
            if let old = fingers[sample.key] {
                guard sample.t > old.t else { return nil }
                live[old.id] = nil
            }
            nextID &+= 1
            fingers[sample.key] = (nextID, sample.t)
        } else {
            // A cancel can carry the same timestamp as the sample before it.
            let lift = sample.phase == .ended || sample.phase == .cancelled
            guard let old = fingers[sample.key], sample.t > old.t || lift && sample.t == old.t
            else { return nil }
            fingers[sample.key]?.t = sample.t
        }
        guard let id = fingers[sample.key]?.id else { return nil }
        live[id] = Touch(id: id, x: sample.x, y: sample.y, radius: sample.radius, phase: sample.phase,
                         t: sample.t)
        return id
    }

    private mutating func frame(at t: Double, sampled: Set<UInt16>) -> TouchFrame {
        let touches = live.values.sorted { $0.id < $1.id }.map { touch in
            var touch = touch
            if !sampled.contains(touch.id) {
                touch.phase = .stationary
                touch.t = t
            }
            return touch
        }
        for touch in touches where touch.phase == .ended || touch.phase == .cancelled {
            live[touch.id] = nil
        }
        fingers = fingers.filter { live[$0.value.id] != nil }
        return TouchFrame(t: t, touches: touches)
    }
}

/// Raw frames waiting to go to the Mac while it records a session.
struct FrameBatch {
    private var frames: [TouchFrame] = []

    mutating func append(_ frame: TouchFrame) { frames.append(frame) }

    /// About every 100 ms while recording; whatever is left as soon as it stops.
    mutating func take(now: Double, recording: Bool) -> [TouchFrame]? {
        guard let first = frames.first, !recording || now - first.t >= 0.1 else { return nil }
        defer { frames = [] }
        return frames
    }
}
