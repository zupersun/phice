import Foundation

/// Messages travel as a 4-byte big-endian length followed by that many bytes of JSON.
public enum FrameCodec {
    /// Anything larger is a protocol error, not a big message: the connection is dropped.
    public static let maxFrame = 1 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var out = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

/// Accumulates bytes off the wire and yields whole messages.
public struct FrameDecoder<T: Decodable> {
    public enum Failure: Error, Equatable {
        case oversized(Int)
    }

    private var buffer = Data()

    public init() {}

    /// Throws on an oversized frame or a body that does not decode; the caller drops the connection.
    public mutating func push(_ bytes: Data) throws -> [T] {
        buffer.append(bytes)
        var out: [T] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start ..< start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= FrameCodec.maxFrame else { throw Failure.oversized(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: start + 4 ..< start + 4 + length)
            buffer.removeSubrange(start ..< start + 4 + length)
            out.append(try JSONDecoder().decode(T.self, from: body))
        }
        return out
    }
}
