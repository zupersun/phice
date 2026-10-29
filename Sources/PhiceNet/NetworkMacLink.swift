import CryptoKit
import Foundation
import Network
import PhiceCore

/// The Mac's side: one TLS-PSK listener, advertised over Bonjour and peer-to-peer Wi-Fi. A paired
/// phone authenticates with its own key and gets a session; a new phone uses the public pairing key
/// and gets a connection that carries only `Handshake`.
@MainActor public final class NetworkMacLink: MacLink {
    public var pairingOpen = false {
        didSet {
            guard pairingOpen != oldValue else { return }
            if !pairingOpen { refusePending() }
            advertise()
            onChange?()
        }
    }
    public private(set) var connectedDevice: String? {
        didSet { if connectedDevice != oldValue { onChange?() } }
    }
    public var onChange: (@MainActor () -> Void)?
    public var onPairingRequest: (@MainActor (PairingRequest) -> Void)?
    public var onMessage: (@MainActor (PhoneToMac) -> Void)?

    private let macName: String
    private let store: any KeyStore
    private let timing: LinkTiming
    private let advertises: Bool
    private var listener: NWListener?
    private var retiring: NWListener?
    private var whenListening: [() -> Void] = []
    /// Kept across relistens, so a phone reconnecting finds the new listener where the old one was.
    private(set) var port: NWEndpoint.Port?
    /// Phones the running listener holds keys for.
    private var phones: Set<String> = []
    /// The identity each handshake in flight offered, as TLS reported it to `admit`.
    private var claimed: [ObjectIdentifier: (metadata: sec_protocol_metadata_t, identity: String)] = [:]
    private var session: FrameChannel<PhoneToMac>?
    /// Authenticated, but yet to say anything.
    private var newcomers: [FrameChannel<PhoneToMac>] = []
    private var pairings: [FrameChannel<Handshake>] = []
    /// The one request the user is being asked about.
    private var pending: FrameChannel<Handshake>?

    public convenience init(macName: String, keyStore: any KeyStore = KeychainKeyStore()) {
        self.init(macName: macName, keyStore: keyStore, timing: LinkTiming(), advertises: true)
    }

    init(macName: String, keyStore: any KeyStore, timing: LinkTiming, advertises: Bool) {
        self.macName = macName
        self.store = keyStore
        self.timing = timing
        self.advertises = advertises
    }

    public func start() {
        guard listener == nil else { return }
        listen()
    }

    public func send(_ message: MacToPhone) {
        session?.send(message)
    }

    // MARK: Listening

    private func listen() {
        phones = Set(store.peers)
        let keys = [(Pairing.identity, Pairing.publicKey)]
            + phones.compactMap { id in store.key(for: id).map { (id, $0) } }
        let parameters = Pairing.parameters(keys: keys) { [weak self] metadata, identity in
            self?.admit(metadata, identity) ?? false
        }
        guard let listener = try? NWListener(using: parameters, on: port ?? .any) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .cancelled = state, self.retiring === listener {
                    self.retiring = nil
                    return self.listen()
                }
                guard self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port
                    let waiting = self.whenListening
                    self.whenListening = []
                    waiting.forEach { $0() }
                case .failed:
                    self.listener = nil
                    listener.cancel()
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        self?.start()
                    }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        advertise()
        listener.start(queue: .main)
    }

    /// A listener's keys are fixed when it starts, so a new key needs a new listener. Connections
    /// already accepted carry on. The new one starts once the old one's socket is closed: until then
    /// the port is in use (measured: EADDRINUSE in about half the runs).
    private func relisten(then done: @escaping () -> Void = {}) {
        whenListening.append(done)
        guard retiring == nil else { return }  // the listener about to start reads the keys afresh
        guard let old = listener else { return listen() }
        listener = nil
        retiring = old
        old.cancel()
    }

    private func advertise() {
        guard advertises, let listener else { return }
        var txt = NWTXTRecord(["id": store.localID, "name": macName])
        if pairingOpen { txt["pair"] = "1" }
        // No name: Bonjour uses the computer's and resolves clashes; the phone shows the TXT name.
        listener.service = NWListener.Service(type: Pairing.serviceType, txtRecord: txt)
    }

    private func admit(_ metadata: sec_protocol_metadata_t, _ identity: String) -> Bool {
        let pairs = identity == Pairing.identity
        guard pairs ? pairingOpen && pending == nil : phones.contains(identity) else { return false }
        // shortcut: entries of handshakes that fail after this are dropped only here; bounded, fine.
        if claimed.count > 32 { claimed.removeAll() }
        claimed[ObjectIdentifier(metadata as AnyObject)] = (metadata, identity)
        return true
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                switch state {
                case .ready: self.ready(connection)
                case .waiting, .failed: connection.cancel()
                case .cancelled: self.closed(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        connection.cancel(unlessReadyWithin: timing.handshake)
    }

    private func ready(_ connection: NWConnection) {
        let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        guard let metadata = tls?.securityProtocolMetadata,
              let claim = claimed.removeValue(forKey: ObjectIdentifier(metadata as AnyObject))
        else { return connection.cancel() }
        if claim.identity == Pairing.identity {
            guard pairingOpen else { return connection.cancel() }
            pairings.append(FrameChannel(connection, deadAfter: timing.deadAfter) { [weak self] in
                self?.handshake($0, on: connection)
            })
        } else {
            newcomers.append(FrameChannel(connection, deadAfter: timing.deadAfter) { [weak self] in
                self?.received($0, on: connection, from: claim.identity)
            })
        }
    }

    private func received(_ message: PhoneToMac, on connection: NWConnection, from phoneID: String) {
        if session?.connection !== connection {
            let index = newcomers.firstIndex { $0.connection === connection }
            guard let index else { return }
            take(newcomers.remove(at: index))
        }
        guard let session else { return }
        switch message {
        case .forget:
            store.setKey(nil, for: phoneID)
            session.close()
            relisten()
        case .hello(let deviceName, _):
            connectedDevice = deviceName
            onMessage?(message)
        default:
            onMessage?(message)
        }
    }

    /// One phone at a time: a new authenticated connection takes over on its first message. A
    /// duplicate the phone raced over another path and dropped never speaks, so it never wins.
    private func take(_ channel: FrameChannel<PhoneToMac>) {
        session?.close()
        // Passing through nil tells the app a new connection began, even with the same device name.
        connectedDevice = nil
        channel.beat(MacToPhone.heartbeat, every: timing.heartbeat)
        session = channel
    }

    private func closed(_ connection: NWConnection) {
        if session?.connection === connection {
            session = nil
            connectedDevice = nil
        }
        if pending?.connection === connection { pending = nil }
        pairings.removeAll { $0.connection === connection }
        newcomers.removeAll { $0.connection === connection }
    }

    // MARK: Pairing

    private func handshake(_ message: Handshake, on connection: NWConnection) {
        guard let channel = pairings.first(where: { $0.connection === connection }) else { return }
        guard case let .request(phoneID, deviceName, publicKey) = message, pending == nil, pairingOpen,
              UUID(uuidString: phoneID) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)) != nil,
              let onPairingRequest
        else { return channel.close() }
        pending = channel
        channel.expire(after: nil)  // the user takes as long as they take
        let shown = String(deviceName.prefix(64))
        onPairingRequest(PairingRequest(deviceName: shown) { [weak self] allow in
            self?.answer(allow, on: channel, phoneID: phoneID, deviceName: deviceName,
                         publicKey: publicKey)
        })
    }

    private func answer(_ allow: Bool, on channel: FrameChannel<Handshake>, phoneID: String,
                        deviceName: String, publicKey: Data) {
        guard pending === channel else { return }  // answered already, or the phone left
        pending = nil
        channel.expire(after: timing.deadAfter)
        guard allow else { return channel.send(Handshake.refuse) }
        let secret = Curve25519.KeyAgreement.PrivateKey()
        let macID = store.localID
        let macKey = secret.publicKey.rawRepresentation
        let transcript = Pairing.transcript(phoneID: phoneID, deviceName: deviceName,
                                            phoneKey: publicKey, macID: macID, macKey: macKey)
        guard let psk = try? Pairing.psk(secret, peer: publicKey, transcript: transcript) else {
            return channel.close()
        }
        store.setKey(psk, for: phoneID)
        // Accept only once the listener knows the key, so the phone's reconnect finds it.
        relisten {
            let proof = Pairing.proof(psk: psk, transcript: transcript)
            channel.send(Handshake.accept(macID: macID, publicKey: macKey, proof: proof))
        }
    }

    private func refusePending() {
        guard let pending else { return }
        self.pending = nil
        pending.send(Handshake.refuse)
        pending.expire(after: timing.deadAfter)
    }
}
