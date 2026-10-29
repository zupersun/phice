import Foundation

/// Plays recorded touches through a recogniser the way the pad does live: each frame at its own
/// time, and the pad's 120 Hz ticks in between, so every timeout fires as it would have.
public enum Replay {
    public static let tickRate = 120.0
    /// Ticking carries on this long after the last frame, past every timeout, so a recording that
    /// ends mid-gesture shows how it resolves (drag lock letting go, say).
    public static let tail = 5.0
    /// An iPhone 17 Pro in landscape with the pill on the left, the pad the recordings come from.
    public static let defaultGeometry = PadGeometry(width: 874, height: 402)

    public static func run(_ frames: [TouchFrame], through recogniser: inout Recogniser) -> [PadEvent] {
        var out: [PadEvent] = []
        play(frames, through: &recogniser) { _, events in out += events }
        return out
    }

    /// Carries on into the Mac's driver at the same instants, standing in for the link: each
    /// instant's events arrive as one message and quiet instants as heartbeats. The phone heartbeats
    /// at 10 Hz; any rate inside the silence timeout posts the same.
    public static func drive(_ frames: [TouchFrame], through recogniser: inout Recogniser,
                             into driver: MacDriver) {
        play(frames, through: &recogniser) { t, events in
            _ = driver.handle(events.isEmpty ? .heartbeat : .events(events), now: t)
            driver.tick(now: t)
        }
    }

    /// Calls `each` at every instant the pad acts: each frame, and the ticks between and after.
    private static func play(_ frames: [TouchFrame], through recogniser: inout Recogniser,
                             each: (Double, [PadEvent]) -> Void) {
        var previous: Double?
        for frame in frames {
            if let previous {
                ticks(after: previous, before: frame.t, through: &recogniser, each: each)
            }
            each(frame.t, recogniser.feed(frame))
            previous = frame.t
        }
        guard let previous else { return }
        ticks(after: previous, before: previous + tail, through: &recogniser, each: each)
    }

    private static func ticks(after start: Double, before end: Double,
                              through recogniser: inout Recogniser,
                              each: (Double, [PadEvent]) -> Void) {
        var k = 1.0
        while start + k / tickRate < end {
            let now = start + k / tickRate
            each(now, recogniser.tick(now: now))
            k += 1
        }
    }

    /// A line of a JSONL file that does not decode. Lines count from 1, blank ones included.
    public struct BadLine: Error, CustomStringConvertible {
        public var line: Int
        public var error: any Error
        public var description: String { "line \(line): \(error)" }
    }

    /// One JSON value per line; blank lines are skipped.
    public static func decodeLines<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        let decoder = JSONDecoder()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return try lines.enumerated().compactMap { index, line in
            guard !line.allSatisfy(\.isWhitespace) else { return nil }
            do { return try decoder.decode(T.self, from: Data(line.utf8)) } catch {
                throw BadLine(line: index + 1, error: error)
            }
        }
    }

    public static func encodeLines<T: Encodable>(_ values: [T]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try values.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }
            .joined()
    }
}
