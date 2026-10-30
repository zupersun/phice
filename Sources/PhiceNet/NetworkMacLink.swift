import CryptoKit
import Foundation
import Network
import PhiceCore

/// The Mac's side: one TLS-PSK listener, advertised over Bonjour and peer-to-peer Wi-Fi. A paired
/// phone authenticates with its own key and gets a session; a new phone uses the public pairing key
/// and gets a connection that carries only `Handshake`, and only while the pairing window is open.
@MainActor public final class NetworkMacLink: MacLink {
    public var pairingOpen = false {
        didSet {
            guard pairingOpen != oldValue else { return }
            if pairingOpen { openWindow() } else { closeWindow() }
            advertise()
            onChange?()
        }
    }
    public private(set) var connectedDevice: String? {
        didSet { if connectedDevice != oldValue { onChange?() } }
    }
    /// From the labels alone: showing the list must never read a key (a keychain prompt on the Mac).
    public var pairedPhones: [PairedPhone] {
        store.labels.map {
            PairedPhone(id: $0.peer, name: Pairing.displayName($0.label), pairedAt: $0.date)
        }
    }
    public var onChange: (@MainActor () -> Void)?
    public var onPairing: (@MainActor (PairingEvent) -> Void)?
    public var onMessage: (@MainActor (PhoneToMac) -> Void)?

    /// Pairing connections held at once, the one being asked about included. More than one lets a
    /// second asker show up as a conflict instead of waiting, unseen, behind the first; one more than
    /// this is a conflict too, so a larger cap costs no security, only memory for the 60 s window.
    /// Room to spare: one phone racing its paths opened 7 (measured), more with extra interfaces.
    static let pairingSlots = 32

    private struct Claim {
        let metadata: sec_protocol_metadata_t
        let identity: String
        let at: ContinuousClock.Instant
    }

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
    private var claimed: [ObjectIdentifier: Claim] = [:]
    private var session: FrameChannel<PhoneToMac>?
    private var sessionPhone: String?
    /// Authenticated, but yet to say anything.
    private var newcomers: [(channel: FrameChannel<PhoneToMac>, phoneID: String)] = []
    /// Pairing connections, which last no longer than the window.
    private var pairings: [FrameChannel<Handshake>] = []
    /// The one request the user is being asked about.
    private var pending: FrameChannel<Handshake>?
    private var window: Task<Void, Never>?

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

    public func remove(_ phoneID: String) {
        store.setKey(nil, for: phoneID)
        phones.remove(phoneID)
        if sessionPhone == phoneID {
            session?.close()
            session = nil
            sessionPhone = nil
            connectedDevice = nil
        }
        newcomers.filter { $0.phoneID == phoneID }.forEach { $0.channel.close() }
        relisten()
        onChange?()
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

    /// Claims expire rather than being flushed, so a flood of handshakes cannot evict a paired
    /// phone's claim in flight; other strangers fail at TLS. A pairing handshake beyond the slots is
    /// a conflict: refusing it at TLS would hide an asker (the user's phone, behind slots an attacker
    /// filled), and nobody can tell which asker is which.
    private func admit(_ metadata: sec_protocol_metadata_t, _ identity: String) -> Bool {
        let now = ContinuousClock.now
        claimed = claimed.filter { now - $0.value.at < timing.handshake }
        if identity == Pairing.identity {
            guard pairingOpen else { return false }
            // A dead handshake's claim cannot be found again (its metadata goes with it), so it stops
            // holding a slot once a live one would have finished: a phone's own retries are no crowd.
            let inFlight = claimed.values.filter {
                $0.identity == Pairing.identity && now - $0.at < timing.deadAfter
            }.count
            guard pairings.count + inFlight < Self.pairingSlots else {
                conflict()
                return false
            }
        } else {
            guard phones.contains(identity), claimed.count < 256 else { return false }
        }
        let claim = Claim(metadata: metadata, identity: identity, at: now)
        claimed[ObjectIdentifier(metadata as AnyObject)] = claim
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
            guard phones.contains(claim.identity) else { return connection.cancel() }  // removed since
            let channel = FrameChannel<PhoneToMac>(connection, deadAfter: timing.deadAfter) {
                [weak self] in
                self?.received($0, on: connection, from: claim.identity)
            }
            newcomers.append((channel, claim.identity))
        }
    }

    private func received(_ message: PhoneToMac, on connection: NWConnection, from phoneID: String) {
        if session?.connection !== connection {
            let index = newcomers.firstIndex { $0.channel.connection === connection }
            guard let index else { return }
            take(newcomers.remove(at: index))
        }
        switch message {
        case .forget:
            remove(phoneID)
        case let .hello(deviceName, appVersion):
            let name = Pairing.displayName(deviceName)
            connectedDevice = name
            onMessage?(.hello(deviceName: name, appVersion: appVersion))
        default:
            onMessage?(message)
        }
    }

    /// One phone at a time: a new authenticated connection takes over on its first message. A
    /// duplicate the phone raced over another path and dropped never speaks, so it never wins.
    private func take(_ newcomer: (channel: FrameChannel<PhoneToMac>, phoneID: String)) {
        session?.close()
        // Passing through nil tells the app a new connection began, even with the same device name.
        connectedDevice = nil
        newcomer.channel.beat(MacToPhone.heartbeat, every: timing.heartbeat)
        session = newcomer.channel
        sessionPhone = newcomer.phoneID
    }

    private func closed(_ connection: NWConnection) {
        if session?.connection === connection {
            session = nil
            sessionPhone = nil
            connectedDevice = nil
        }
        pairings.removeAll { $0.connection === connection }
        newcomers.removeAll { $0.channel.connection === connection }
        if pending?.connection === connection {
            // Closing the window too, so nobody can step in the moment the asking phone leaves.
            pending = nil
            onPairing?(.withdrawn)
            pairingOpen = false
        }
    }

    // MARK: Pairing

    private func openWindow() {
        window = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.pairingWindow)
            guard !Task.isCancelled else { return }
            self?.pairingOpen = false
        }
    }

    /// The end of the window is every pairing connection's deadline, however much it sends.
    private func closeWindow() {
        window?.cancel()
        window = nil
        if let pending {
            self.pending = nil
            pairings.removeAll { $0 === pending }
            pending.finish(with: Handshake.refuse)
            onPairing?(.withdrawn)
        }
        let open = pairings
        pairings = []
        open.forEach { $0.close() }
    }

    private func handshake(_ message: Handshake, on connection: NWConnection) {
        guard let channel = pairings.first(where: { $0.connection === connection }) else { return }
        // A request never replaces a key: the phone takes a fresh id for every pairing.
        guard case let .request(phoneID, deviceName, publicKey) = message, pairingOpen,
              UUID(uuidString: phoneID) != nil, !store.peers.contains(phoneID),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)) != nil
        else { return channel.close() }
        if let pending {
            // The same phone asking twice is misbehaving; two phones asking is a conflict.
            return pending === channel ? channel.close() : conflict()
        }
        guard let onPairing else { return channel.close() }
        pending = channel
        channel.expire(after: nil)  // the user takes their time; the window's end still applies
        let shown = Pairing.displayName(deviceName)
        onPairing(.request(PairingRequest(deviceName: shown) { [weak self] allow in
            self?.answer(allow, on: channel, phoneID: phoneID, deviceName: deviceName,
                         publicKey: publicKey)
        }))
    }

    /// Nobody can tell which asker is the user's phone, so nobody gets in: every pairing connection
    /// is refused and the window closes.
    private func conflict() {
        let askers = pairings
        pending = nil
        pairings = []
        askers.forEach { $0.finish(with: Handshake.refuse) }
        onPairing?(.conflict)
        pairingOpen = false
    }

    private func answer(_ allow: Bool, on channel: FrameChannel<Handshake>, phoneID: String,
                        deviceName: String, publicKey: Data) {
        guard pending === channel else { return }  // answered, withdrawn, or refused in a conflict
        pending = nil
        pairings.removeAll { $0 === channel }  // it outlives the window, to carry the answer
        channel.expire(after: timing.deadAfter)
        defer { pairingOpen = false }  // one answer per window
        guard allow else { return channel.finish(with: Handshake.refuse) }
        let secret = Curve25519.KeyAgreement.PrivateKey()
        let macID = store.localID
        let macKey = secret.publicKey.rawRepresentation
        let transcript = Pairing.transcript(phoneID: phoneID, deviceName: deviceName,
                                            phoneKey: publicKey, macID: macID, macKey: macKey)
        guard let psk = try? Pairing.psk(secret, peer: publicKey, transcript: transcript) else {
            return channel.close()
        }
        store.setKey(psk, label: Pairing.displayName(deviceName), for: phoneID)
        onChange?()
        // Accept only once the listener knows the key, so the phone's reconnect finds it.
        relisten {
            let proof = Pairing.proof(psk: psk, transcript: transcript)
            channel.finish(with: Handshake.accept(macID: macID, publicKey: macKey, proof: proof))
        }
    }
}
