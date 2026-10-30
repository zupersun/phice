import Foundation
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
public struct PairingRequest: Sendable, Identifiable {
    /// So the alert binds to the one request it shows.
    public let id = UUID()
    /// Already cleaned: no control or format characters, at most 32 of them.
    public let deviceName: String
    public let respond: @Sendable @MainActor (Bool) -> Void

    public init(deviceName: String, respond: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.deviceName = deviceName
        self.respond = respond
    }
}

/// A phone this Mac holds a key for.
public struct PairedPhone: Sendable, Equatable, Identifiable {
    public var id: String
    /// The name it paired with, already cleaned.
    public var name: String
    public var pairedAt: Date?

    public init(id: String, name: String, pairedAt: Date?) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

public enum PairingEvent: Sendable {
    /// Show Allow / Don't Allow.
    case request(PairingRequest)
    /// The request on screen is gone (its phone left, or the window closed): dismiss the alert. The
    /// window is closed either way; pairing again takes Pair New iPhone again.
    case withdrawn
    /// Two devices asked at once: both were refused and the window closed.
    case conflict
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
    /// Whether a new phone may pair. The UI sets it true from "Pair New iPhone"; the link sets it
    /// back to false, firing `onChange`, after 60 s, after any answer (Allow or Don't Allow), on a
    /// conflict, when the asking phone leaves (`.withdrawn`), or when the UI sets it false. A request
    /// on screen when it closes is withdrawn.
    var pairingOpen: Bool { get set }
    var connectedDevice: String? { get }
    /// Changes fire `onChange`.
    var pairedPhones: [PairedPhone] { get }
    var onChange: (@MainActor () -> Void)? { get set }
    var onPairing: (@MainActor (PairingEvent) -> Void)? { get set }
    var onMessage: (@MainActor (PhoneToMac) -> Void)? { get set }
    func start()
    func send(_ message: MacToPhone)
    /// Deletes the phone's key and drops it if connected; it has to pair again.
    func remove(_ phoneID: String)
}
