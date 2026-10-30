import Foundation

/// Fits `Momentum.Parameters` to a recording, in the trackpad counts the parameters are written in
/// (the HID event's unaccelerated deltas; pixels only if the recording has none).
///
/// The model: every 8 ms momentum keeps `decay` of its speed, blending linearly toward `tailDecay`
/// as the speed falls below `tailSpeed`. All three are searched on a grid, each candidate scored by
/// replaying the recorded runs.
func fitMomentum(path: String) throws -> String {
    struct Step { var t: Double, size: Double, phase: Int, momentum: Int }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var steps: [Step] = []
    var pixelsOnly = false
    for line in text.split(separator: "\n") {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              o["kind"] as? String == "scroll", let t = o["t"] as? Double,
              let px = o["px"] as? [Double], px.count == 2
        else { continue }
        let raw = o["raw"] as? [Double]
        if raw == nil { pixelsOnly = true }
        let d = raw ?? px
        steps.append(Step(t: t, size: hypot(d[0], d[1]), phase: o["phase"] as? Int ?? 0,
                          momentum: o["momentum"] as? Int ?? 0))
    }

    // Lift speed: the fingers' last four steps. Momentum runs: from begin to end after a lift.
    var lifts: [(speed: Double, coasted: Bool)] = []
    var runs: [[(t: Double, speed: Double)]] = []
    // Runs the next flick ended: the system stops momentum when fingers land, so their last speed
    // says nothing about where momentum dies by itself.
    var cutShort: Set<Int> = []
    var moving: [Step] = []
    var run: [(t: Double, speed: Double)]?
    var last: Step?
    for s in steps {
        defer { last = s }
        if s.momentum == 0 {
            if s.phase == 1 { moving = [] }
            if s.phase == 1, let previous = last, previous.momentum == 3, s.t - previous.t < 0.1 {
                cutShort.insert(runs.count - 1)
            }
            if s.phase == 2 { moving = Array((moving + [s]).suffix(5)) }
            if s.phase == 4 || s.phase == 8, let a = moving.first, let b = moving.last, b.t > a.t {
                lifts.append((moving.dropFirst().reduce(0) { $0 + $1.size } / (b.t - a.t), false))
            }
            continue
        }
        if s.momentum == 1 { run = []; if !lifts.isEmpty { lifts[lifts.count - 1].coasted = true } }
        if let previous = last, s.t > previous.t, s.size > 0 {
            run?.append((s.t, s.size / (s.t - previous.t)))
        }
        if s.momentum == 3, let done = run { runs.append(done); run = nil }
    }

    let stepCount = runs.reduce(0) { $0 + $1.count }
    guard stepCount >= 3 else {
        return "too few momentum steps in \(path) (\(stepCount)); flick the trackpad a few times"
    }

    // Replays each run from its first step and scores the step sizes in counts. Fitting the
    // step-to-step ratios instead overshot by 10%: once steps are a few counts they are mostly
    // rounding. A cut-short run is scored as far as it got; one that coasted also over any steps
    // a candidate adds after the trackpad had stopped.
    let replayStop = 30.0  // Phice's stopSpeed: half a count per 60 Hz frame
    func replay(_ decay: Double, _ tail: Double, _ tailSpeed: Double) -> (sse: Double, n: Int) {
        var sse = 0.0, n = 0
        // From the second step: the first one's interval runs from the lift, not a 60 Hz frame.
        for (i, r) in runs.enumerated() where r.count > 2 {
            var v = r[1].speed, k = 2
            while k < r.count || (!cutShort.contains(i) && v >= replayStop) {
                let dt = k < r.count ? r[k].t - r[k - 1].t : 1.0 / 60
                if v >= replayStop {
                    let w = max(0, (tailSpeed - v) / tailSpeed)
                    v *= pow(decay - (decay - tail) * w, dt / 0.008)
                }
                let observed = k < r.count ? r[k].speed * dt : 0
                sse += pow((v >= replayStop ? v * dt : 0) - observed, 2)
                n += 1
                k += 1
            }
        }
        return (sse, n)
    }

    var best = (sse: Double.infinity, decay: 0.0, tail: 0.0, tailSpeed: 0.0, n: 1)
    for decay in stride(from: 0.95, through: 0.99, by: 0.001) {
        for tail in stride(from: 0.80, through: decay, by: 0.005) {
            for tailSpeed in stride(from: 50.0, through: 4000, by: 50) {
                let (sse, n) = replay(decay, tail, tailSpeed)
                if sse < best.sse { best = (sse, decay, tail, tailSpeed, n) }
            }
        }
    }

    func median(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.sorted()[xs.count / 2] }
    func show(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "?" }
    let stop = median(runs.indices.filter { !cutShort.contains($0) }.compactMap { runs[$0].last?.speed })
    let coasted = lifts.filter(\.coasted).map(\.speed)
    let stayed = lifts.filter { !$0.coasted }.map(\.speed)
    // Halfway, on a log scale, between the fastest lift that did not coast and the slowest that did.
    let start = coasted.min().map { low in
        stayed.filter { $0 < low }.max().map { ($0 * low).squareRoot() } ?? low
    }
    let rate = median(runs.flatMap { r in zip(r, r.dropFirst()).map { 1 / ($1.t - $0.t) } })
    let rms = (best.sse / Double(best.n)).squareRoot()
    let unit = pixelsOnly ? "pixels (no raw deltas recorded: not comparable to Phice's counts)"
        : "trackpad counts (400 per inch)"
    return """
        momentum fit from \(runs.count) runs (\(stepCount) steps; \(runs.count - cutShort.count) \
        coasted to a stop, and only those constrain the tail), in \(unit):
          Momentum.Parameters: decay \(String(format: "%.3f", best.decay)), \
        tailDecay \(String(format: "%.3f", best.tail)), tailSpeed \(show(best.tailSpeed)), \
        startSpeed \(show(start)), stopSpeed \(show(stop)) (the last step's speed, not a threshold)
          rms error of the replayed steps: \(String(format: "%.2f", rms)) counts
          momentum steps arrive at \(show(rate)) Hz
          lifts that coasted: \(coasted.count), \(show(coasted.min()))...\(show(coasted.max())) per s; \
        lifts that did not: \(stayed.count), \(show(stayed.min()))...\(show(stayed.max())) per s
        """
}
