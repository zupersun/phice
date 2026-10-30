import Foundation
import PhiceNet

/// The fake phone's id and keys in a JSON file, so it pairs once and then reconnects like a phone.
final class FileKeyStore: KeyStore {
    private struct Contents: Codable {
        var localID = UUID().uuidString
        var entries: [String: Entry] = [:]
    }

    private struct Entry: Codable {
        var key: Data
        var label: String
        var date: Date
    }

    let url: URL
    private var contents: Contents

    init(url: URL) {
        self.url = url
        contents = (try? JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))) ?? Contents()
        save()
    }

    var localID: String { contents.localID }
    var labels: [KeyLabel] {
        contents.entries.sorted { $0.key < $1.key }
            .map { KeyLabel(peer: $0.key, label: $0.value.label, date: $0.value.date) }
    }

    func entry(for peer: String) -> KeyEntry? {
        contents.entries[peer].map { KeyEntry(key: $0.key, label: $0.label, date: $0.date) }
    }

    func setKey(_ key: Data?, label: String, for peer: String) {
        contents.entries[peer] = key.map { Entry(key: $0, label: label, date: Date()) }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }
}
