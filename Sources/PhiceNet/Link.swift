import PhiceCore

public enum LinkState: Sendable, Equatable {
    case idle, searching, pairing, connecting, connected, unreachable
}

/// A Mac found on the network or over peer-to-peer Wi-Fi.
public struct DiscoveredMac: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// This phone already holds a key for it.
    public var paired: Bool
    /// Its setup window is open, so it accepts a new phone.
    public var pairingOpen: Bool

    public init(id: String, name: String, paired: Bool, pairingOpen: Bool) {
        self.id = id
        self.name = name
        self.paired = paired
        self.pairingOpen = pairingOpen
    }
}

/// A phone asking to pair. The Mac's UI shows Allow / Don't Allow and calls `respond` once.
public struct PairingRequest: Sendable {
    public let deviceName: String
    public let respond: @Sendable @MainActor (Bool) -> Void

    public init(deviceName: String, respond: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.deviceName = deviceName
        self.respond = respond
    }
}

/// The phone's side: find Macs, pair once, then stay connected to the paired one.
@MainActor public protocol PhoneLink: AnyObject {
    var macs: [DiscoveredMac] { get }
    var state: LinkState { get }
    /// `macs` or `state` changed.
    var onChange: (@MainActor () -> Void)? { get set }
    var onMessage: (@MainActor (MacToPhone) -> Void)? { get set }
    func start()
    func pair(with mac: DiscoveredMac)
    func send(_ message: PhoneToMac)
    func forget()
}

/// The Mac's side: advertise, accept a paired phone, ask the user about a new one.
@MainActor public protocol MacLink: AnyObject {
    /// Advertise that a new phone may pair: true only while the setup window is open.
    var pairingOpen: Bool { get set }
    var connectedDevice: String? { get }
    var onChange: (@MainActor () -> Void)? { get set }
    var onPairingRequest: (@MainActor (PairingRequest) -> Void)? { get set }
    var onMessage: (@MainActor (PhoneToMac) -> Void)? { get set }
    func start()
    func send(_ message: MacToPhone)
}
