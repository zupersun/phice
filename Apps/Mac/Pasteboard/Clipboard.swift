import AppKit
import Foundation
import PhiceCore

/// The system pasteboard on one side, the store on the other. Main thread only.
final class Clipboard {
    let store: ClipStore
    private let pasteboard: NSPasteboard
    /// The change count we last read or wrote, so our own writes are not copied back in.
    private var seen: Int

    init(pasteboard: NSPasteboard = .general, store: ClipStore) {
        self.pasteboard = pasteboard
        self.store = store
        seen = pasteboard.changeCount
    }

    var changeCount: Int { pasteboard.changeCount }

    /// Something was copied on the Mac itself: history only, the pill is not touched.
    func poll(now: Date = Date()) {
        guard pasteboard.changeCount != seen else { return }
        capture(asPill: false, now: now)
    }

    /// Look at the pasteboard without keeping anything, so a later poll sees only later copies.
    func discardChanges() { seen = pasteboard.changeCount }

    /// Read the pasteboard into the store now. nil when it holds nothing, something private, or
    /// more than a clipboard should.
    @discardableResult
    func capture(asPill: Bool, now: Date = Date()) -> ClipItem? {
        seen = pasteboard.changeCount
        guard let items = snapshot() else { return nil }
        return store.add(items, asPill: asPill, now: now)
    }

    /// Put a stored item back with every type it had. The paste keystroke is the caller's.
    func write(itemID: String) -> Bool {
        guard let items = store.types(for: itemID) else { return false }
        let objects = items.map { types -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for (type, data) in types {
                object.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return object
        }
        pasteboard.clearContents()
        let wrote = pasteboard.writeObjects(objects)
        seen = pasteboard.changeCount
        return wrote
    }

    /// The pill's item was dragged out and pasted.
    func pastedOut(_ id: String) {
        if store.pill?.id == id { store.clearPill() }
    }

    /// A type with no bytes still counts: the privacy markers are exactly that.
    private func snapshot() -> [[String: Data]]? {
        var total = 0
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var types: [String: Data] = [:]
            for type in item.types {
                let data = item.data(forType: type) ?? Data()
                total += data.count
                types[type.rawValue] = data
            }
            if !types.isEmpty { items.append(types) }
        }
        return total <= ClipStore.maxItemBytes && !items.isEmpty ? items : nil
    }
}

enum ClipboardPayload {
    /// A frame over 1 MiB drops the connection, and thumbnails are the bulk of it, so the phone is
    /// sent the newest items that fit well inside that.
    static let budget = 400_000

    static func items(from history: [ClipItem]) -> [ClipItem] {
        var used = 0
        var sent: [ClipItem] = []
        for item in history {
            // Base64 inflates the thumbnail by a third; the rest is keys, id, date and escaping.
            used += (item.thumbnail?.count ?? 0) * 4 / 3 + item.preview.utf8.count * 2 + 200
            if used > budget && !sent.isEmpty { break }
            sent.append(item)
        }
        return sent
    }
}
