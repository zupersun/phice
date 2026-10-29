import Foundation
import Network
import PhiceCore
@testable import PhiceNet

extension LinkTiming {
    static let fast = LinkTiming(heartbeat: .milliseconds(50), deadAfter: .milliseconds(500),
                                 unreachableAfter: .milliseconds(300), handshake: .seconds(3),
                                 firstRetry: .milliseconds(20), maxRetry: .milliseconds(200))
}

func randomKey() -> Data {
    Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
}

/// Polls until `condition` holds; false if `timeout` passes first.
@MainActor func eventually(within timeout: Duration = .seconds(5),
                           _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A Mac and a phone over loopback, the phone pointed straight at the Mac's port instead of Bonjour.
@MainActor final class Rig {
    let macStore = InMemoryKeyStore()
    let phoneStore = InMemoryKeyStore()
    let mac: NetworkMacLink
    let phone: NetworkPhoneLink
    var atMac: [PhoneToMac] = []
    var atPhone: [MacToPhone] = []
    var requests: [String] = []

    init() {
        mac = NetworkMacLink(macName: "Test Mac", keyStore: macStore, timing: .fast, advertises: false)
        phone = NetworkPhoneLink(deviceName: "Test iPhone", keyStore: phoneStore, timing: .fast,
                                 browses: false)
        mac.onMessage = { [unowned self] in atMac.append($0) }
        phone.onMessage = { [unowned self] in atPhone.append($0) }
    }

    var hellos: Int {
        atMac.filter { if case .hello = $0 { true } else { false } }.count
    }

    /// Both sides hold a key already, as after an earlier pairing. Call before `start`.
    func seedKeys() {
        let key = randomKey()
        macStore.setKey(key, for: phoneStore.localID)
        phoneStore.setKey(key, for: macStore.localID)
    }

    func start() async -> Bool {
        mac.start()
        guard await eventually({ mac.port != nil }) else { return false }
        phone.start()
        return true
    }

    func showMac(pairingOpen: Bool = false) {
        phone.see([Sighting(id: macStore.localID, name: "Test Mac", pairingOpen: pairingOpen,
                            endpoint: .hostPort(host: "127.0.0.1", port: mac.port!))])
    }
}

/// A hand-driven client, for what a well-behaved phone link never sends.
@MainActor final class RawClient {
    let connection: NWConnection
    private(set) var state = NWConnection.State.setup
    /// The Mac closed it.
    private(set) var ended = false

    /// `identity` nil means plain TCP, no TLS at all.
    init(port: NWEndpoint.Port, identity: String?, key: Data = Pairing.publicKey) {
        let parameters = identity.map { Pairing.parameters(keys: [($0, key)]) } ?? .tcp
        connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.state = state }
        }
        connection.start(queue: .main)
        receive()
    }

    var ready: Bool { state == .ready }

    var refused: Bool {
        switch state {
        case .waiting, .failed: true
        default: false
        }
    }

    func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .idempotent)
    }

    func send(_ message: PhoneToMac) {
        send(try! FrameCodec.encode(message))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] _, _, done, err in
            MainActor.assumeIsolated {
                if done || err != nil { self?.ended = true } else { self?.receive() }
            }
        }
    }
}
