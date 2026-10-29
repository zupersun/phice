import Foundation
import PhiceNet

/// The fake phone's id and keys in a JSON file, so it pairs once and then reconnects like a phone.
final class FileKeyStore: KeyStore {
    private struct Contents: Codable {
        var localID = UUID().uuidString
        var keys: [String: Data] = [:]
    }

    let url: URL
    private var contents: Contents

    init(url: URL) {
        self.url = url
        contents = (try? JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))) ?? Contents()
        save()
    }

    var localID: String { contents.localID }
    var peers: [String] { contents.keys.keys.sorted() }

    func key(for peer: String) -> Data? { contents.keys[peer] }

    func setKey(_ key: Data?, for peer: String) {
        contents.keys[peer] = key
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }
}
