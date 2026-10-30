import Foundation

/// The Shortcuts app's command line, which is how a drop can hand the copied item to a shortcut.
enum ShortcutsCLI {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func list() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = tool
                process.arguments = ["list"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: []) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: parse(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Fire and forget: a shortcut can run for as long as it likes. `temporary` input is deleted
    /// afterwards.
    static func run(_ name: String, input: URL, temporary: Bool) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name, "--input-path", input.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if temporary {
            process.terminationHandler = { _ in try? FileManager.default.removeItem(at: input) }
        }
        if (try? process.run()) == nil, temporary { try? FileManager.default.removeItem(at: input) }
    }
}

/// The copied item as a file, which is what a shortcut takes as input.
enum ShortcutInput {
    struct Input {
        var url: URL
        /// We wrote it, so we delete it. A file the user copied is never ours to delete, wherever
        /// its path points.
        var temporary: Bool
    }

    static func file(for items: [[String: Data]], in directory: URL) -> Input? {
        guard let item = items.first else { return nil }
        if let data = item["public.file-url"], let text = String(data: data, encoding: .utf8),
           let url = URL(string: text), url.isFileURL {
            return Input(url: url, temporary: false)
        }
        let (type, ext) = [("public.png", "png"), ("public.tiff", "tiff"), ("public.jpeg", "jpg"),
                           ("public.utf8-plain-text", "txt")].first { item[$0.0] != nil } ?? ("", "")
        guard let data = item[type] else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        return (try? data.write(to: url)) != nil ? Input(url: url, temporary: true) : nil
    }
}
