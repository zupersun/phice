import Foundation
import PhiceCore

/// A `FakePoster` that also writes every call to a file, one JSON line each, so a test outside the
/// process can see exactly what the driver asked the cursor to do. Main thread only.
///
/// Each line is a flat object with sorted keys, no timestamps, and numbers exactly as the driver
/// produced them (nil fields are left out):
///
///     {"call":"move","dx":1.5,"dy":-2,"dragging":"left"}
///     {"call":"moveTo","x":10,"y":20,"dragging":"left"}
///     {"call":"button","button":"left","down":true,"clicks":2}
///     {"call":"scroll","dx":0,"dy":3.25,"phase":"changed","momentum":"end"}
///     {"call":"shortcut","shortcut":"missionControl"}
///     {"call":"forceClick"}
///     {"call":"perform","action":"copy"}   (or "cut", or "shortcut" with "name")
///     {"call":"paste","itemID":"abc"}
final class LoggingPoster: EventPoster {
    private let inner = FakePoster()
    private var file: FileHandle?

    /// Appends to `url`, creating it if need be. If it cannot be opened the poster still works and
    /// says so on stderr, rather than failing a test run before it starts.
    init(log url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            self.file = file
        } catch {
            NSLog("PHICE cannot write the fake-poster log %@: %@", url.path, "\(error)")
        }
    }

    var cursor: (x: Double, y: Double) { inner.cursor }

    func move(dx: Double, dy: Double, dragging: MouseButton?) {
        record { $0.move(dx: dx, dy: dy, dragging: dragging) }
    }

    func moveTo(x: Double, y: Double, dragging: MouseButton?) {
        record { $0.moveTo(x: x, y: y, dragging: dragging) }
    }

    func button(_ button: MouseButton, down: Bool, clicks: Int) {
        record { $0.button(button, down: down, clicks: clicks) }
    }

    func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?) {
        record { $0.scroll(dx: dx, dy: dy, phase: phase, momentum: momentum) }
    }

    func shortcut(_ shortcut: Shortcut) { record { $0.shortcut(shortcut) } }

    func forceClick() { record { $0.forceClick() } }

    func perform(_ action: DropAction) -> Bool { record { $0.perform(action) } }

    func paste(itemID: String) { record { $0.paste(itemID: itemID) } }

    /// Forward to the fake, then log what it recorded, so the log cannot disagree with it.
    private func record<T>(_ call: (FakePoster) -> T) -> T {
        let result = call(inner)
        for logged in inner.calls { try? file?.write(contentsOf: PosterCall(logged).line()) }
        inner.clear()
        return result
    }
}

/// `FakePoster.Call` as JSON. The fake lives in PhiceCore and is not Codable; this mirrors it.
struct PosterCall: Codable, Equatable {
    var call: String
    var dx: Double?
    var dy: Double?
    var x: Double?
    var y: Double?
    var dragging: String?
    var button: String?
    var down: Bool?
    var clicks: Int?
    var phase: String?
    var momentum: String?
    var shortcut: String?
    var action: String?
    var name: String?
    var itemID: String?

    init(_ source: FakePoster.Call) {
        switch source {
        case let .move(dx, dy, dragging):
            call = "move"; self.dx = dx; self.dy = dy; self.dragging = dragging?.rawValue
        case let .moveTo(x, y, dragging):
            call = "moveTo"; self.x = x; self.y = y; self.dragging = dragging?.rawValue
        case let .button(button, down, clicks):
            call = "button"; self.button = button.rawValue; self.down = down; self.clicks = clicks
        case let .scroll(dx, dy, phase, momentum):
            call = "scroll"; self.dx = dx; self.dy = dy
            self.phase = phase?.rawValue; self.momentum = momentum?.rawValue
        case let .shortcut(shortcut):
            call = "shortcut"; self.shortcut = shortcut.rawValue
        case .forceClick:
            call = "forceClick"
        case let .perform(drop):
            call = "perform"
            switch drop {
            case .copy: action = "copy"
            case .cut: action = "cut"
            case .shortcut(let name): action = "shortcut"; self.name = name
            }
        case let .paste(itemID):
            call = "paste"; self.itemID = itemID
        }
    }

    /// The JSON line, newline included. Never fails: a non-finite number becomes a string.
    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
