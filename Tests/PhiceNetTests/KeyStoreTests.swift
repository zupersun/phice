import Foundation
import Security
import Testing
@testable import PhiceNet

/// A throwaway keychain service and its UserDefaults key, both removed when `body` returns. Never the
/// real `com.phice.pairing`.
private func withThrowawayService(_ body: (String) -> Void) {
    let service = "com.phice.pairing.test-\(UUID().uuidString)"
    defer {
        UserDefaults.standard.removeObject(forKey: "\(service).local-id")
        for account in ["local-id", "peer"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                           kSecAttrAccount: account] as CFDictionary)
        }
    }
    body(service)
}

/// The keychain's own `local-id` item for `service`, read by attributes only, so never a prompt.
private func keychainHasLocalID(_ service: String) -> Bool {
    SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                         kSecAttrAccount: "local-id", kSecReturnAttributes: true] as CFDictionary,
                        nil) == errSecSuccess
}

@Test func theKeychainStoreKeepsKeysLabelsAndDates() {
    withThrowawayService { service in
        let store = KeychainKeyStore(service: service)
        #expect(store.peers.isEmpty)

        store.setKey(Data([1, 2, 3]), for: "peer")
        store.setKey(Data([4]), label: "Jasper’s iPhone", for: "peer")
        let entry = store.entry(for: "peer")
        #expect(entry?.key == Data([4]))
        #expect(entry?.label == "Jasper’s iPhone")
        #expect(entry?.date.map { abs($0.timeIntervalSinceNow) < 60 } == true)
        #expect(store.peers == ["peer"])
        #expect(store.labels.map(\.label) == ["Jasper’s iPhone"])
        #expect(store.labels.first?.date == entry?.date)

        store.setKey(nil, for: "peer")
        #expect(store.key(for: "peer") == nil)
        #expect(store.peers.isEmpty)
    }
}

/// Keys stored before labels existed have none, and the legacy macOS keychain reports the service
/// name in its place: that reads as no label, not as a phone named after the service.
@Test func aKeyStoredWithoutALabelReadsAsUnlabelled() {
    withThrowawayService { service in
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecAttrAccount: "peer", kSecValueData: Data([1])] as CFDictionary, nil)
        let store = KeychainKeyStore(service: service)
        #expect(store.labels.map(\.label) == [""])
        #expect(store.entry(for: "peer")?.label == "")
    }
}

/// The id is public (it is in the Bonjour TXT record), so it lives in UserDefaults; once there, the
/// keychain is never asked for it, so a rebuilt Mac app can never come up with a different one.
@Test func theLocalIDIsReadFromUserDefaultsFirst() {
    withThrowawayService { service in
        UserDefaults.standard.set("FROM-DEFAULTS", forKey: "\(service).local-id")
        #expect(KeychainKeyStore(service: service).localID == "FROM-DEFAULTS")
        #expect(!keychainHasLocalID(service))
    }
}

@Test func aLocalIDInTheKeychainMovesToUserDefaultsOnce() {
    withThrowawayService { service in
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecAttrAccount: "local-id", kSecValueData: Data("OLD-ID".utf8)] as CFDictionary,
                   nil)
        #expect(KeychainKeyStore(service: service).localID == "OLD-ID")
        #expect(UserDefaults.standard.string(forKey: "\(service).local-id") == "OLD-ID")
    }
}

@Test func aFirstLocalIDGoesToUserDefaultsAndTheKeychain() {
    withThrowawayService { service in
        let id = KeychainKeyStore(service: service).localID
        #expect(UUID(uuidString: id) != nil)
        #expect(UserDefaults.standard.string(forKey: "\(service).local-id") == id)
        #expect(keychainHasLocalID(service))
        #expect(KeychainKeyStore(service: service).localID == id)
    }
}

/// What a store starts with when UserDefaults has no id, from what reading the old keychain item
/// gave. A read that fails for any reason but absence (another build's item behind a prompt that was
/// denied, cancelled or not allowed) gets a new id, and the item is left exactly as it is.
@Test(arguments: [
    (errSecSuccess, Data("OLD-ID".utf8), "OLD-ID", false),
    (errSecItemNotFound, nil, nil, true),
    (errSecAuthFailed, nil, nil, false),
    (errSecUserCanceled, nil, nil, false),
    (errSecInteractionNotAllowed, nil, nil, false),
    (errSecSuccess, Data([0xFF, 0xFE]), nil, false),  // not UTF-8: unusable, but not ours to replace
] as [(OSStatus, Data?, String?, Bool)])
func theFirstLocalIDFollowsWhatTheKeychainSaid(status: OSStatus, data: Data?, kept: String?,
                                               writesItem: Bool) {
    let start = KeychainKeyStore.startingID(status: status, data: data)
    if let kept { #expect(start.id == kept) } else { #expect(UUID(uuidString: start.id) != nil) }
    #expect(start.writeItem == writesItem)
}

/// Showing the paired phones must never read a key: on the Mac that read can raise a keychain
/// prompt (seen on device, on the main thread).
@MainActor @Test func listingPairedPhonesNeverReadsAKey() {
    let store = CountingKeyStore()
    store.setKey(randomKey(), label: "Jasper’s iPhone", for: UUID().uuidString)
    let mac = NetworkMacLink(macName: "Test Mac", keyStore: store, timing: .fast, advertises: false)
    #expect(mac.pairedPhones.map(\.name) == ["Jasper’s iPhone"])
    #expect(mac.pairedPhones.first?.pairedAt != nil)

    let macID = UUID().uuidString
    store.setKey(randomKey(), label: UUID().uuidString, for: macID)
    let phone = NetworkPhoneLink(deviceName: "Test iPhone", keyStore: store, timing: .fast,
                                 browses: false)
    phone.see([Sighting(id: macID, name: "Test Mac", pairingOpen: false,
                        endpoint: .hostPort(host: "127.0.0.1", port: 9))])  // not started: list only
    #expect(phone.macs.map(\.paired) == [true])
    #expect(store.secretReads == 0)
}

/// Counts reads of key data.
final class CountingKeyStore: KeyStore {
    private let inner = InMemoryKeyStore()
    private(set) var secretReads = 0

    var localID: String { inner.localID }
    var labels: [KeyLabel] { inner.labels }

    func entry(for peer: String) -> KeyEntry? {
        secretReads += 1
        return inner.entry(for: peer)
    }

    func setKey(_ key: Data?, label: String, for peer: String) {
        inner.setKey(key, label: label, for: peer)
    }
}
