import Foundation

/// Fits `Momentum.Parameters` to a recording, in the trackpad counts the parameters are written in
/// (the HID event's unaccelerated deltas; pixels only if the recording has none).
///
/// The model: every 8 ms momentum keeps `decay` of its speed, blending linearly toward `tailDecay`
/// as the speed falls below `tailSpeed`. For each candidate tail speed that is a linear least-squares
/// problem in the two decays, so the tail speed is searched and the decays solved for.
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
    var moving: [Step] = []
    var run: [(t: Double, speed: Double)]?
    var last: Step?
    for s in steps {
        defer { last = s }
        if s.momentum == 0 {
            if s.phase == 1 { moving = [] }
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

    var samples: [(speed: Double, keep: Double)] = []
    for r in runs {
        for (a, b) in zip(r, r.dropFirst()) where b.speed > 0 && a.speed > 0 {
            samples.append((a.speed, pow(b.speed / a.speed, 0.008 / (b.t - a.t))))
        }
    }
    guard samples.count >= 3 else {
        return "too few momentum steps in \(path) (\(samples.count)); flick the trackpad a few times"
    }

    var best = (sse: Double.infinity, decay: 0.0, tail: 0.0, tailSpeed: 0.0)
    for tailSpeed in stride(from: 10.0, through: 3000, by: 10) {
        // keep = decay * (1 - w) + tail * w, w = how far below the tail speed: solve for both decays.
        var suu = 0.0, suw = 0.0, sww = 0.0, suk = 0.0, swk = 0.0
        for (speed, keep) in samples {
            let w = max(0, (tailSpeed - speed) / tailSpeed), u = 1 - w
            suu += u * u; suw += u * w; sww += w * w; suk += u * keep; swk += w * keep
        }
        let det = suu * sww - suw * suw
        guard det > 1e-12 else { continue }
        let decay = (suk * sww - swk * suw) / det, tail = (swk * suu - suk * suw) / det
        let sse = samples.reduce(0) {
            let w = max(0, (tailSpeed - $1.speed) / tailSpeed)
            return $0 + pow(decay * (1 - w) + tail * w - $1.keep, 2)
        }
        if sse < best.sse { best = (sse, decay, tail, tailSpeed) }
    }

    func median(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.sorted()[xs.count / 2] }
    func show(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "?" }
    let stop = median(runs.compactMap { $0.last?.speed })
    let coasted = lifts.filter(\.coasted).map(\.speed)
    let stayed = lifts.filter { !$0.coasted }.map(\.speed)
    // Halfway between the fastest lift that did not coast and the slowest that did.
    let start = coasted.min().map { low in
        stayed.filter { $0 < low }.max().map { ($0 + low) / 2 } ?? low
    }
    let rate = median(runs.flatMap { r in zip(r, r.dropFirst()).map { 1 / ($1.t - $0.t) } })
    let rms = (best.sse / Double(samples.count)).squareRoot()
    let unit = pixelsOnly ? "pixels (no raw deltas recorded: not comparable to Phice's counts)"
        : "trackpad counts (400 per inch)"
    return """
        momentum fit from \(runs.count) runs (\(samples.count) steps), in \(unit):
          Momentum.Parameters: decay \(String(format: "%.4f", best.decay)), \
        tailDecay \(String(format: "%.4f", best.tail)), tailSpeed \(show(best.tailSpeed)), \
        startSpeed \(show(start)), stopSpeed \(show(stop))
          rms error of the 8 ms retention: \(String(format: "%.4f", rms))
          momentum steps arrive at \(show(rate)) Hz
          lifts that coasted: \(coasted.count), \(show(coasted.min()))...\(show(coasted.max())) per s; \
        lifts that did not: \(stayed.count), \(show(stayed.min()))...\(show(stayed.max())) per s
        """
}
