import Foundation
import PhiceCore

/// The clipboard history and the pill's item, kept on disk so a Cut survives a crash. The phone only
/// ever sees previews; the bytes of every pasteboard type stay here. One property list per item
/// under `blobs/`, and `history.json` for the ordered previews and which one the pill holds.
final class ClipStore {
    static let maxItems = 50
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maxItemBytes = 64 << 20

    /// Newest first.
    private(set) var history: [ClipItem] = []
    var pill: ClipItem? { history.first { $0.id == pillID } }
    /// History or pill changed.
    var onChange: (() -> Void)?

    private var pillID: String?
    private let directory: URL
    private var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var index: URL { directory.appendingPathComponent("history.json") }

    private struct Index: Codable {
        var items: [ClipItem]
        var pill: String?
    }

    init(directory: URL, now: Date = Date()) {
        self.directory = directory
        if let data = try? Data(contentsOf: index),
           let saved = try? JSONDecoder().decode(Index.self, from: data) {
            history = saved.items.filter {
                FileManager.default.fileExists(atPath: blob(for: $0.id).path)
            }
            pillID = history.contains { $0.id == saved.pill } ? saved.pill : nil
        }
        if evict(now: now) { save() }
    }

    /// Remember a snapshot, optionally as what the pill holds. nil when it is private or cannot be
    /// kept.
    @discardableResult
    func add(_ items: [[String: Data]], asPill: Bool = false, now: Date = Date()) -> ClipItem? {
        guard !ClipPreview.isConcealed(items), let summary = ClipPreview.summary(of: items)
        else { return nil }
        let item: ClipItem
        if let newest = history.first, newest.kind == summary.kind, newest.preview == summary.preview,
           types(for: newest.id) == items {
            item = newest
        } else {
            item = ClipItem(id: UUID().uuidString, kind: summary.kind, preview: summary.preview,
                            thumbnail: summary.thumbnail, date: now)
            guard write(items, for: item.id) else { return nil }
            history.insert(item, at: 0)
        }
        if asPill { pillID = item.id }
        _ = evict(now: now)
        save()
        onChange?()
        return item
    }

    /// Every pasteboard type of every pasteboard item. Only ids in the history are read, so an id
    /// from the phone can never name another file.
    func types(for id: String) -> [[String: Data]]? {
        guard history.contains(where: { $0.id == id }),
              let data = try? Data(contentsOf: blob(for: id)) else { return nil }
        return try? PropertyListDecoder().decode([[String: Data]].self, from: data)
    }

    /// The pill's item was pasted out; it stays in history.
    func clearPill() {
        guard pillID != nil else { return }
        pillID = nil
        save()
        onChange?()
    }

    func prune(now: Date) {
        guard evict(now: now) else { return }
        save()
        onChange?()
    }

    /// Drops what is too old or beyond the cap, oldest first; the pill's item is never dropped.
    private func evict(now: Date) -> Bool {
        var keep: [ClipItem] = []
        var room = Self.maxItems
        for item in history {   // newest first, so the cap lands on the oldest
            let isPill = item.id == pillID
            if isPill || (room > 0 && now.timeIntervalSince(item.date) <= Self.maxAge) {
                keep.append(item)
                room -= 1
            }
        }
        let dropped = history.filter { item in !keep.contains { $0.id == item.id } }
        history = keep
        for item in dropped { try? FileManager.default.removeItem(at: blob(for: item.id)) }
        return !dropped.isEmpty
    }

    private func blob(for id: String) -> URL { blobs.appendingPathComponent(id) }

    /// Private to the user: copied text can be anything.
    private func prepare() {
        try? FileManager.default.createDirectory(
            at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func write(_ items: [[String: Data]], for id: String) -> Bool {
        prepare()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(items) else { return false }
        return (try? data.write(to: blob(for: id), options: .atomic)) != nil
    }

    private func save() {
        prepare()
        guard let data = try? JSONEncoder().encode(Index(items: history, pill: pillID)) else { return }
        try? data.write(to: index, options: .atomic)
    }
}
