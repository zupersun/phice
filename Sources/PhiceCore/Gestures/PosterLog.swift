import Foundation

/// Poster calls as JSON lines: what `phice-replay --driver` prints and the Mac agent's
/// `--fake-poster` log writes, so an offline replay and a live run diff line for line. One object
/// per call keyed by its case, keys sorted, nil fields left out, no timestamps.
public enum PosterLog {
    public static func line(_ call: FakePoster.Call) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // A log line must never take the agent down, not even for an infinite delta.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(Line(call)) else { return "\(call)" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func lines(_ calls: [FakePoster.Call]) -> String {
        calls.map { line($0) + "\n" }.joined()
    }

    /// `FakePoster.Call`'s own shape, so synthesized Codable spells it as it would spell the call:
    /// the case is the key and an unlabelled payload is `_0`. Codable cannot be synthesized for the
    /// call itself outside the file that declares it.
    private enum Line: Encodable {
        case move(dx: Double, dy: Double, dragging: MouseButton?)
        case moveTo(x: Double, y: Double, dragging: MouseButton?)
        case button(MouseButton, down: Bool, clicks: Int)
        case scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?)
        case shortcut(Shortcut)
        case forceClick
        case perform(DropAction)
        case paste(itemID: String)

        init(_ call: FakePoster.Call) {
            switch call {
            case let .move(dx, dy, dragging): self = .move(dx: dx, dy: dy, dragging: dragging)
            case let .moveTo(x, y, dragging): self = .moveTo(x: x, y: y, dragging: dragging)
            case let .button(button, down, clicks): self = .button(button, down: down, clicks: clicks)
            case let .scroll(dx, dy, phase, momentum):
                self = .scroll(dx: dx, dy: dy, phase: phase, momentum: momentum)
            case let .shortcut(shortcut): self = .shortcut(shortcut)
            case .forceClick: self = .forceClick
            case let .perform(action): self = .perform(action)
            case let .paste(itemID): self = .paste(itemID: itemID)
            }
        }
    }
}
