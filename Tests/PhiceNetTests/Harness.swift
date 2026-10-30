import CryptoKit
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
    /// Every pairing event, as text: "request <name>", "withdrawn", "conflict".
    var events: [String] = []
    /// The requests shown, in order.
    var shown: [PairingRequest] = []
    /// Answers each request this way at once; nil leaves it on screen.
    var autoAnswer: Bool?
    var requests: [String] { shown.map(\.deviceName) }
    /// `connectedDevice` at each of the Mac's `onChange` calls.
    var macChanges: [String?] = []

    init(timing: LinkTiming = .fast) {
        mac = NetworkMacLink(macName: "Test Mac", keyStore: macStore, timing: timing, advertises: false)
        phone = NetworkPhoneLink(deviceName: "Test iPhone", keyStore: phoneStore, timing: timing,
                                 browses: false)
        mac.onPairing = { [unowned self] event in
            switch event {
            case .request(let request):
                events.append("request \(request.deviceName)")
                shown.append(request)
                if let autoAnswer { request.respond(autoAnswer) }
            case .withdrawn: events.append("withdrawn")
            case .conflict: events.append("conflict")
            }
        }
        mac.onMessage = { [unowned self] in atMac.append($0) }
        mac.onChange = { [unowned self] in macChanges.append(mac.connectedDevice) }
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

/// A TLS-PSK server that lets one phone in and then says nothing, like a Mac that has hung.
@MainActor final class SilentMac {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var port: NWEndpoint.Port?
    /// When each connection became ready.
    private(set) var ready: [ContinuousClock.Instant] = []

    init(phoneID: String, key: Data) {
        listener = try! NWListener(using: Pairing.parameters(keys: [(phoneID, key)]))
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.connections.append(connection)
                connection.stateUpdateHandler = { [weak self] state in
                    if case .ready = state { MainActor.assumeIsolated { self?.ready.append(.now) } }
                }
                connection.start(queue: .main)
            }
        }
        listener.stateUpdateHandler = { [weak self, listener] state in
            if case .ready = state { MainActor.assumeIsolated { self?.port = listener.port } }
        }
        listener.start(queue: .main)
    }
}

/// A new phone speaking `Handshake` by hand, keeping what the Mac answers.
@MainActor final class PairingClient {
    let connection: NWConnection
    let phoneID: String
    let secret = Curve25519.KeyAgreement.PrivateKey()
    private var decoder = FrameDecoder<Handshake>()
    private(set) var answers: [Handshake] = []
    private(set) var state = NWConnection.State.setup
    /// The Mac closed it.
    private(set) var ended = false

    init(port: NWEndpoint.Port, phoneID: String = UUID().uuidString) {
        self.phoneID = phoneID
        connection = NWConnection(host: "127.0.0.1", port: port,
                                  using: Pairing.parameters(keys: [(Pairing.identity,
                                                                    Pairing.publicKey)]))
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.state = state }
        }
        connection.start(queue: .main)
        receive()
    }

    func request(name: String) {
        let request = Handshake.request(phoneID: phoneID, deviceName: name,
                                        publicKey: secret.publicKey.rawRepresentation)
        connection.send(content: try! FrameCodec.encode(request), completion: .idempotent)
    }

    /// The key the Mac stored for this phone, if it accepted.
    func psk(name: String) -> Data? {
        guard case let .accept(macID, macKey, _)? = answers.first else { return nil }
        let transcript = Pairing.transcript(phoneID: phoneID, deviceName: name,
                                            phoneKey: secret.publicKey.rawRepresentation,
                                            macID: macID, macKey: macKey)
        return try? Pairing.psk(secret, peer: macKey, transcript: transcript)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, err in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, let got = try? self.decoder.push(data) { self.answers += got }
                if done || err != nil { self.ended = true } else { self.receive() }
            }
        }
    }
}
