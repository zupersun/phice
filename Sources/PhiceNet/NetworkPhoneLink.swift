import CryptoKit
import Foundation
import Network
import PhiceCore

/// A Mac as the browser last saw it.
struct Sighting: Equatable {
    var id: String
    var name: String
    var pairingOpen: Bool
    var endpoint: NWEndpoint
}

extension Sighting {
    init?(_ result: NWBrowser.Result) {
        guard case let .bonjour(txt) = result.metadata, let id = txt["id"] else { return nil }
        self.init(id: id, name: txt["name"] ?? id, pairingOpen: txt["pair"] == "1",
                  endpoint: result.endpoint)
    }
}

/// The phone's side: browse for Macs, pair once, then stay connected to the paired Mac whenever it
/// is in sight. One paired Mac at a time; pairing another replaces it.
@MainActor public final class NetworkPhoneLink: PhoneLink {
    public private(set) var macs: [DiscoveredMac] = [] {
        didSet { if macs != oldValue { onChange?() } }
    }
    public private(set) var state = LinkState.idle {
        didSet { if state != oldValue { onChange?() } }
    }
    public var onChange: (@MainActor () -> Void)?
    public var onMessage: (@MainActor (MacToPhone) -> Void)?

    private struct Attempt {
        let macID: String
        let secret: Curve25519.KeyAgreement.PrivateKey
        let connection: NWConnection
        var channel: FrameChannel<Handshake>?
    }

    private let deviceName: String
    private let store: any KeyStore
    private let timing: LinkTiming
    private let browses: Bool
    private var browser: NWBrowser?
    private var sightings: [String: Sighting] = [:]
    /// The connection to the paired Mac, from the first attempt until it closes.
    private var link: NWConnection?
    private var session: FrameChannel<MacToPhone>?
    private var pairing: Attempt?
    private var retry: Task<Void, Never>?
    private var unseen: Task<Void, Never>?
    private var failures = 0

    public convenience init(deviceName: String, keyStore: any KeyStore = KeychainKeyStore()) {
        self.init(deviceName: deviceName, keyStore: keyStore, timing: LinkTiming(), browses: true)
    }

    init(deviceName: String, keyStore: any KeyStore, timing: LinkTiming, browses: Bool) {
        self.deviceName = deviceName
        self.store = keyStore
        self.timing = timing
        self.browses = browses
    }

    public func start() {
        guard state == .idle else { return }
        state = .searching
        if browses { browse() }
        reconnect()
    }

    public func pair(with mac: DiscoveredMac) {
        guard state != .idle, let sighting = sightings[mac.id] else { return }
        hangUp()
        pairing?.connection.cancel()
        let parameters = Pairing.parameters(keys: [(Pairing.identity, Pairing.publicKey)])
        let connection = NWConnection(to: sighting.endpoint, using: parameters)
        pairing = Attempt(macID: mac.id, secret: .init(), connection: connection)
        state = .pairing
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, let attempt = self.pairing, attempt.connection === connection else {
                    return connection.cancel()
                }
                switch state {
                case .ready:
                    let channel = FrameChannel<Handshake>(connection, deadAfter: nil) { [weak self] in
                        self?.handshake($0)
                    }
                    self.pairing?.channel = channel
                    let mine = attempt.secret.publicKey.rawRepresentation
                    channel.send(Handshake.request(phoneID: self.store.localID,
                                                   deviceName: self.deviceName, publicKey: mine))
                case .waiting, .failed: connection.cancel()
                case .cancelled:
                    self.pairing = nil
                    self.state = .searching
                    self.reconnect()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        connection.cancel(unlessReadyWithin: timing.handshake)
    }

    public func send(_ message: PhoneToMac) {
        guard state == .connected else { return }
        session?.send(message)
    }

    /// Removes the key here and, if connected, tells the Mac to remove its copy too.
    public func forget() {
        if let session {
            self.session = nil
            link = nil
            session.finish(with: PhoneToMac.forget)
        }
        hangUp()
        if let attempt = pairing {
            pairing = nil
            attempt.connection.cancel()
        }
        for id in store.peers { store.setKey(nil, for: id) }
        unseen?.cancel()
        unseen = nil
        failures = 0
        if state != .idle { state = .searching }
        refreshMacs()
    }

    /// What the browser saw; tests call it directly with a loopback endpoint.
    func see(_ found: [Sighting]) {
        sightings = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        refreshMacs()
        reconnect()
    }

    // MARK: Discovery

    private func browse() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Pairing.serviceType, domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Sighting.init)
            MainActor.assumeIsolated { self?.see(found) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                browser.cancel()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.browse()
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func refreshMacs() {
        macs = sightings.values.map {
            DiscoveredMac(id: $0.id, name: $0.name, paired: store.key(for: $0.id) != nil,
                          pairingOpen: $0.pairingOpen)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: The paired Mac

    /// Connect to the paired Mac if it is in sight and nothing else is under way.
    private func reconnect() {
        guard state != .idle, pairing == nil, link == nil, retry == nil else { return }
        guard let macID = store.peers.first, let key = store.key(for: macID) else {
            return state = .searching
        }
        guard let mac = sightings[macID] else { return waitToSee() }
        unseen?.cancel()
        unseen = nil
        state = .connecting
        let parameters = Pairing.parameters(keys: [(store.localID, key)])
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        link = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.link === connection else { return connection.cancel() }
                switch state {
                case .ready: self.connected(connection)
                case .waiting, .failed: connection.cancel()
                case .cancelled: self.dropped()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        connection.cancel(unlessReadyWithin: timing.handshake)
    }

    private func waitToSee() {
        if state != .unreachable { state = .searching }
        guard unseen == nil else { return }
        unseen = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.unreachableAfter)
            guard let self, !Task.isCancelled else { return }
            self.unseen = nil
            if self.state == .searching, self.link == nil, self.pairing == nil {
                self.state = .unreachable
            }
        }
    }

    private func connected(_ connection: NWConnection) {
        failures = 0
        let session = FrameChannel<MacToPhone>(connection, deadAfter: timing.deadAfter) { [weak self] in
            guard self?.link === connection, $0 != .heartbeat else { return }
            self?.onMessage?($0)
        }
        self.session = session
        // Before `state`, so nothing the app sends on `.connected` can overtake the hello.
        session.send(PhoneToMac.hello(deviceName: deviceName, appVersion: Self.appVersion))
        session.beat(PhoneToMac.heartbeat, every: timing.heartbeat)
        state = .connected
    }

    private func dropped() {
        hangUp()
        guard state != .idle else { return }
        state = .connecting
        failures += 1
        let delay = min(timing.firstRetry * (1 << min(failures - 1, 8)), timing.maxRetry)
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            self.reconnect()
        }
    }

    private func hangUp() {
        let connection = link
        link = nil
        session?.close()
        session = nil
        connection?.cancel()
        retry?.cancel()
        retry = nil
    }

    // MARK: Pairing

    private func handshake(_ message: Handshake) {
        guard let attempt = pairing else { return }
        guard case let .accept(macID, macKey, proof) = message, macID == attempt.macID else {
            return attempt.connection.cancel()  // a refusal, or not an answer at all
        }
        let transcript = Pairing.transcript(phoneID: store.localID, deviceName: deviceName,
                                            phoneKey: attempt.secret.publicKey.rawRepresentation,
                                            macID: macID, macKey: macKey)
        guard let psk = try? Pairing.psk(attempt.secret, peer: macKey, transcript: transcript),
              Pairing.verify(proof, psk: psk, transcript: transcript)
        else { return attempt.connection.cancel() }
        for other in store.peers where other != macID { store.setKey(nil, for: other) }
        store.setKey(psk, for: macID)
        pairing = nil
        attempt.channel?.close()
        refreshMacs()
        reconnect()
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
