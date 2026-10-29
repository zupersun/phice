import Foundation
import PhiceCore

/// A `FakePoster` that also writes every call to a file, one JSON line each, so a test outside the
/// process can see exactly what the driver asked the cursor to do. The lines are `PosterLog`'s, the
/// same ones `phice-replay --driver` prints, so a live run and an offline replay diff line for line.
/// Main thread only.
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
        for logged in inner.calls {
            try? file?.write(contentsOf: Data((PosterLog.line(logged) + "\n").utf8))
        }
        inner.clear()
        return result
    }
}
