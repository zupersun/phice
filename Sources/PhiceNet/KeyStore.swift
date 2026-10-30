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

/// Pairing keys by peer id, plus this device's own id.
public protocol KeyStore: AnyObject {
    /// This device's stable id, made on first use. Never listed in `peers`.
    var localID: String { get }
    var peers: [String] { get }
    func entry(for peer: String) -> KeyEntry?
    /// Stores the key with `label`, dated now; a nil key removes the entry.
    func setKey(_ key: Data?, label: String, for peer: String)
}

public extension KeyStore {
    func key(for peer: String) -> Data? { entry(for: peer)?.key }

    func setKey(_ key: Data?, for peer: String) { setKey(key, label: "", for: peer) }
}

public final class InMemoryKeyStore: KeyStore {
    public let localID: String
    private var entries: [String: KeyEntry] = [:]

    public init(localID: String = UUID().uuidString) {
        self.localID = localID
    }

    public var peers: [String] { entries.keys.sorted() }

    public func entry(for peer: String) -> KeyEntry? { entries[peer] }

    public func setKey(_ key: Data?, label: String, for peer: String) {
        entries[peer] = key.map { KeyEntry(key: $0, label: label, date: Date()) }
    }
}

/// Generic passwords, account = peer id, the label in `kSecAttrLabel` and the date the item's own.
/// This device only, and readable after first unlock so a locked phone can still reconnect. On the
/// Mac this is the login keychain: the data-protection keychain needs a team-signed app, which the
/// self-signed agent is not (-34018).
public final class KeychainKeyStore: KeyStore {
    private static let localAccount = "local-id"
    private let service: String
    public let localID: String

    public init(service: String = "com.phice.pairing") {
        self.service = service
        if let data = Self.read(service, Self.localAccount)?[kSecValueData as String] as? Data,
           let id = String(data: data, encoding: .utf8) {
            localID = id
        } else {
            localID = UUID().uuidString
            Self.write(service, Self.localAccount, Data(localID.utf8), label: "")
        }
    }

    public var peers: [String] {
        var query = Self.query(service, nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let items = items as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0 != Self.localAccount }.sorted()
    }

    public func entry(for peer: String) -> KeyEntry? {
        guard let item = Self.read(service, peer), let key = item[kSecValueData as String] as? Data
        else { return nil }
        return KeyEntry(key: key, label: item[kSecAttrLabel as String] as? String ?? "",
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
