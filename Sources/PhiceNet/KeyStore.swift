import Foundation
import Security

/// A pairing key and what is kept with it.
public struct KeyEntry: Sendable, Equatable {
    public var key: Data
    /// The Mac keeps the phone's name here; the phone keeps the id it uses with that Mac.
    public var label: String
    /// When it was stored.
    public var date: Date?

    public init(key: Data, label: String, date: Date?) {
        self.key = key
        self.label = label
        self.date = date
    }
}

/// What is kept beside a key, which can be read without the key itself.
public struct KeyLabel: Sendable, Equatable {
    public var peer: String
    public var label: String
    public var date: Date?

    public init(peer: String, label: String, date: Date?) {
        self.peer = peer
        self.label = label
        self.date = date
    }
}

/// Pairing keys by peer id, plus this device's own id.
public protocol KeyStore: AnyObject {
    /// This device's stable id, made on first use. Never listed in `labels`.
    var localID: String { get }
    /// Every key's label and date, by peer, read without the keys: listing must never need a
    /// secret, which on a Mac can mean a keychain prompt.
    var labels: [KeyLabel] { get }
    /// The one read of a key itself.
    func entry(for peer: String) -> KeyEntry?
    /// Stores the key with `label`, dated now; a nil key removes the entry.
    func setKey(_ key: Data?, label: String, for peer: String)
}

public extension KeyStore {
    var peers: [String] { labels.map(\.peer) }

    func key(for peer: String) -> Data? { entry(for: peer)?.key }

    func setKey(_ key: Data?, for peer: String) { setKey(key, label: "", for: peer) }
}

public final class InMemoryKeyStore: KeyStore {
    public let localID: String
    private var entries: [String: KeyEntry] = [:]

    public init(localID: String = UUID().uuidString) {
        self.localID = localID
    }

    public var labels: [KeyLabel] {
        entries.sorted { $0.key < $1.key }
            .map { KeyLabel(peer: $0.key, label: $0.value.label, date: $0.value.date) }
    }

    public func entry(for peer: String) -> KeyEntry? { entries[peer] }

    public func setKey(_ key: Data?, label: String, for peer: String) {
        entries[peer] = key.map { KeyEntry(key: $0, label: label, date: Date()) }
    }
}

/// Generic passwords, account = peer id, the label in `kSecAttrLabel` and the date the item's own.
/// This device only, and readable after first unlock so a locked phone can still reconnect. On the
/// Mac this is the login keychain: the data-protection keychain needs a team-signed app, which the
/// self-signed agent is not (-34018).
///
/// The local id is public (it is in the Bonjour TXT record), so it lives in UserDefaults. It used to
/// live in the keychain, where a self-signed app's items are bound to the cdhash of the build that
/// made them: after a rebuild the read needed a prompt, failed, and the Mac advertised a new random
/// id that its paired phone never looked for.
public final class KeychainKeyStore: KeyStore {
    private static let localAccount = "local-id"
    private let service: String
    public let localID: String

    public init(service: String = "com.phice.pairing") {
        self.service = service
        let remembered = "\(service).local-id"
        if let id = UserDefaults.standard.string(forKey: remembered) {
            localID = id
            return
        }
        // Once: from the keychain item it used to live in.
        var query = Self.query(service, Self.localAccount)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let start = Self.startingID(status: status, data: item as? Data)
        localID = start.id
        if start.writeItem { Self.write(service, Self.localAccount, Data(localID.utf8), label: "") }
        UserDefaults.standard.set(localID, forKey: remembered)
    }

    /// The id to start with when UserDefaults has none, from reading the old keychain item. Only an
    /// absent item is written (still, for older builds); one that failed to read for any other reason
    /// (denied, cancelled, interaction not allowed) is left exactly as it is.
    static func startingID(status: OSStatus, data: Data?) -> (id: String, writeItem: Bool) {
        if status == errSecSuccess, let data, let id = String(data: data, encoding: .utf8) {
            return (id, false)
        }
        return (UUID().uuidString, status == errSecItemNotFound)
    }

    public var labels: [KeyLabel] {
        var query = Self.query(service, nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true  // never kSecReturnData: no prompt for a list
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let items = items as? [[String: Any]] else { return [] }
        return items.compactMap { item -> KeyLabel? in
            guard let peer = item[kSecAttrAccount as String] as? String, peer != Self.localAccount
            else { return nil }
            return KeyLabel(peer: peer, label: label(of: item),
                            date: item[kSecAttrCreationDate as String] as? Date)
        }.sorted { $0.peer < $1.peer }
    }

    /// The legacy macOS keychain gives an item stored without a label its service's name instead
    /// (keys from before labels existed); that is no label, not a phone named "com.phice.pairing".
    private func label(of item: [String: Any]) -> String {
        let label = item[kSecAttrLabel as String] as? String ?? ""
        return label == service ? "" : label
    }

    public func entry(for peer: String) -> KeyEntry? {
        guard let item = Self.read(service, peer), let key = item[kSecValueData as String] as? Data
        else { return nil }
        return KeyEntry(key: key, label: label(of: item),
                        date: item[kSecAttrCreationDate as String] as? Date)
    }

    public func setKey(_ key: Data?, label: String, for peer: String) {
        SecItemDelete(Self.query(service, peer) as CFDictionary)
        if let key { Self.write(service, peer, key, label: label) }
    }

    private static func query(_ service: String, _ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        query[kSecAttrAccount as String] = account
        return query
    }

    private static func read(_ service: String, _ account: String) -> [String: Any]? {
        var query = query(service, account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? [String: Any]
    }

    private static func write(_ service: String, _ account: String, _ data: Data, label: String) {
        var item = query(service, account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
