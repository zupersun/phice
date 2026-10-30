import Foundation
import Testing
@testable import PhiceCore

// Ground truth: this Mac's built-in trackpad recorded by `trackpad-probe` (flicks, 2026-10-30) at
// its default tracking speed. For every report, the HID event's time and unaccelerated counts, and
// the points macOS posted for it. macOS posts whole points and carries the rest, so strokes are
// compared by their net displacement.

private struct Report: Decodable {
    var t: Double
    var raw: [Double]
    var d: [Double]
}

/// Reports split at pauses longer than 50 ms; only strokes that moved the cursor 20 points or more.
private func strokes() throws -> [[Report]] {
    let url = try #require(Bundle.module.url(forResource: "trackpad.moves", withExtension: "jsonl",
                                             subdirectory: "Fixtures"))
    let reports = try Replay.decodeLines(Report.self, from: Data(contentsOf: url))
    var strokes: [[Report]] = [[]]
    for (previous, report) in zip([nil] + reports, reports) {
        if let previous, report.t - previous.t > 0.05 { strokes.append([]) }
        strokes[strokes.count - 1].append(report)
    }
    return strokes.filter { posted($0) >= 20 }
}

private func posted(_ stroke: [Report]) -> Double {
    hypot(stroke.reduce(0) { $0 + $1.d[0] }, stroke.reduce(0) { $0 + $1.d[1] })
}

/// The finger motion of a report in pad points, under Phice's unit assumption. The nudge keeps a
/// whole count whole on the way back: Apple floors the speed, and 3.9999 counts would read as 3.
private func points(_ r: Report) -> (Double, Double) {
    let scale = (1 + 1e-12) / Trackpad.countsPerPoint
    return (r.raw[0] * scale, r.raw[1] * scale)
}

/// Every stroke within 2% of what macOS posted, and all of them together within 1%.
private func expectMatches(_ ours: [Double], _ theirs: [Double]) {
    for (o, p) in zip(ours, theirs) { #expect(close(o, p, 0.02), "posted \(p), ours \(o)") }
    #expect(close(ours.reduce(0, +), theirs.reduce(0, +), 0.01))
}

@Test func pointerMatchesTheRealTrackpad() throws {
    let strokes = try strokes()
    #expect(strokes.count >= 10)
    let ours = strokes.map { stroke in
        var accel = PointerAcceleration(curves: ThisMac.pointer, trackingSpeed: 0.6875)
        var x = 0.0, y = 0.0, last: Double?
        for r in stroke {
            let dt = min(max(last.map { r.t - $0 } ?? MacDriver.maxInterval, 0), MacDriver.maxInterval)
            last = r.t
            let (dx, dy) = points(r)
            let out = accel.apply(dx: dx, dy: dy, dt: dt)
            x += out.dx
            y += out.dy
        }
        return hypot(x, y)
    }
    expectMatches(ours, strokes.map(posted))
}

@Test func phoneSamplesPostWhatTheTrackpadDid() throws {
    // The phone samples touches at 240 Hz, so the same motion reaches the Mac as two moves per
    // trackpad report, each half the distance in half the time.
    let strokes = try strokes()
    let ours = strokes.map { stroke in
        let poster = FakePoster()
        var settings = TrackpadSettings()
        settings.trackingSpeed = 0.6875
        let driver = MacDriver(poster: poster, settings: settings,
                               curves: ThisMac.pointer, scrollCurves: ThisMac.scroll)
        var last: Double?
        for r in stroke {
            let (dx, dy) = points(r)
            let mid = last.map { ($0 + r.t) / 2 } ?? r.t - Trackpad.reportInterval / 2
            last = r.t
            driver.send(.move(dx: dx / 2, dy: dy / 2, t: mid), .move(dx: dx / 2, dy: dy / 2, t: r.t))
        }
        return hypot(poster.cursor.x, poster.cursor.y)
    }
    expectMatches(ours, strokes.map(posted))
}
