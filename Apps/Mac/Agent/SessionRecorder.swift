import Foundation
import PhiceCore

/// Writes the phone's raw touches to Application Support/Phice/recordings/<timestamp>.jsonl, one
/// frame per line, for replaying a session offline.
final class SessionRecorder {
    private let folder: URL
    private var file: FileHandle?
    private let encoder = JSONEncoder()

    init(directory: URL) {
        folder = directory.appendingPathComponent("recordings", isDirectory: true)
    }

    func start(now: Date = Date()) {
        stop()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let url = folder.appendingPathComponent("\(stamp.string(from: now)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        file = try? FileHandle(forWritingTo: url)
    }

    func append(_ frames: [TouchFrame]) {
        guard let file else { return }
        for frame in frames {
            guard var line = try? encoder.encode(frame) else { continue }
            line.append(0x0A)
            try? file.write(contentsOf: line)
        }
    }

    func stop() {
        try? file?.close()
        file = nil
    }
}
