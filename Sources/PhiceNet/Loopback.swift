import Foundation
import PhiceCore

/// An in-memory phone and Mac wired to each other, so both apps can be built and tested before
/// the real transport exists. Messages are delivered on the next main-actor turn, like a network.
public enum Loopback {
    @MainActor public static func pair() -> (phone: LoopbackPhoneLink, mac: LoopbackMacLink) {
        let phone = LoopbackPhoneLink()
        let mac = LoopbackMacLink()
        phone.peer = mac
        mac.peer = phone
        return (phone, mac)
    }
}

@MainActor public final class LoopbackPhoneLink: PhoneLink {
    weak var peer: LoopbackMacLink?
    public private(set) var macs: [DiscoveredMac] = []
    public private(set) var state = LinkState.idle { didSet { onChange?() } }
    public var onChange: (@MainActor () -> Void)?
    public var onMessage: (@MainActor (MacToPhone) -> Void)?

    public func start() {
        state = .searching
        refresh()
    }

    func refresh() {
        guard let peer else { return }
        macs = [DiscoveredMac(id: "loopback", name: "Loopback Mac", paired: state == .connected,
                              pairingOpen: peer.pairingOpen)]
        onChange?()
    }

    public func pair(with mac: DiscoveredMac) {
        guard let peer else { return }
        state = .pairing
        let request = PairingRequest(deviceName: "Loopback iPhone") { [weak self, weak peer] ok in
            self?.state = ok ? .connected : .searching
            if ok, peer?.pairedPhones.isEmpty == true {
                peer?.pairedPhones = [PairedPhone(id: "loopback", name: "Loopback iPhone",
                                                  pairedAt: Date())]
            }
            peer?.connectedDevice = ok ? "Loopback iPhone" : nil
            self?.refresh()
        }
        peer.onPairing?(.request(request))
        peer.onPairingRequest?(request)
    }

    public func send(_ message: PhoneToMac) {
        guard state == .connected else { return }
        Task { @MainActor [weak peer] in peer?.onMessage?(message) }
    }

    public func forget() {
        state = .searching
        peer?.connectedDevice = nil
        refresh()
    }
}

@MainActor public final class LoopbackMacLink: MacLink {
    weak var peer: LoopbackPhoneLink?
    public var pairingOpen = false { didSet { peer?.refresh() } }
    public internal(set) var connectedDevice: String? { didSet { onChange?() } }
    public internal(set) var pairedPhones: [PairedPhone] = [] { didSet { onChange?() } }
    public var onChange: (@MainActor () -> Void)?
    /// Requests only; the window's timing (closing after 60 s or an answer) is not modelled here.
    public var onPairing: (@MainActor (PairingEvent) -> Void)?
    /// The requests alone, as the iOS dev build and its tests take them.
    public var onPairingRequest: (@MainActor (PairingRequest) -> Void)?
    public var onMessage: (@MainActor (PhoneToMac) -> Void)?

    public func start() {}

    public func remove(_ phoneID: String) {
        pairedPhones.removeAll { $0.id == phoneID }
        if pairedPhones.isEmpty { peer?.forget() }
    }

    public func send(_ message: MacToPhone) {
        guard connectedDevice != nil else { return }
        Task { @MainActor [weak peer] in peer?.onMessage?(message) }
    }
}
