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
        var previous: Double?
        for frame in frames {
            if let previous { out += ticks(after: previous, before: frame.t, through: &recogniser) }
            out += recogniser.feed(frame)
            previous = frame.t
        }
        if let previous { out += ticks(after: previous, before: previous + tail, through: &recogniser) }
        return out
    }

    private static func ticks(after start: Double, before end: Double,
                              through recogniser: inout Recogniser) -> [PadEvent] {
        var out: [PadEvent] = []
        var k = 1.0
        while start + k / tickRate < end {
            out += recogniser.tick(now: start + k / tickRate)
            k += 1
        }
        return out
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
