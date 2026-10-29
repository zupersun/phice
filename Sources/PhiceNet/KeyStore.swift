import Foundation
import Security

/// Pairing keys by peer id, plus this device's own id.
public protocol KeyStore: AnyObject {
    /// This device's stable id, made on first use. Never listed in `peers`.
    var localID: String { get }
    var peers: [String] { get }
    func key(for peer: String) -> Data?
    /// nil removes the key.
    func setKey(_ key: Data?, for peer: String)
}

public final class InMemoryKeyStore: KeyStore {
    public let localID: String
    private var keys: [String: Data] = [:]

    public init(localID: String = UUID().uuidString) {
        self.localID = localID
    }

    public var peers: [String] { keys.keys.sorted() }

    public func key(for peer: String) -> Data? { keys[peer] }

    public func setKey(_ key: Data?, for peer: String) { keys[peer] = key }
}

/// Generic passwords, account = peer id. This device only, and readable after first unlock so a
/// locked phone can still reconnect. On the Mac this is the login keychain: the data-protection
/// keychain needs a team-signed app, which the self-signed agent is not (-34018).
public final class KeychainKeyStore: KeyStore {
    private static let localAccount = "local-id"
    private let service: String
    public let localID: String

    public init(service: String = "com.phice.pairing") {
        self.service = service
        if let data = Self.read(service, Self.localAccount),
           let id = String(data: data, encoding: .utf8) {
            localID = id
        } else {
            localID = UUID().uuidString
            Self.write(service, Self.localAccount, Data(localID.utf8))
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

    public func key(for peer: String) -> Data? { Self.read(service, peer) }

    public func setKey(_ key: Data?, for peer: String) {
        SecItemDelete(Self.query(service, peer) as CFDictionary)
        if let key { Self.write(service, peer, key) }
    }

    private static func query(_ service: String, _ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        query[kSecAttrAccount as String] = account
        return query
    }

    private static func read(_ service: String, _ account: String) -> Data? {
        var query = query(service, account)
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess ? data as? Data : nil
    }

    private static func write(_ service: String, _ account: String, _ data: Data) {
        var item = query(service, account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
