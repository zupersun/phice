import Foundation
import PhiceCore
import PhiceNet
@testable import Phice

/// A `MacLink` the test drives by hand: it can close pairing the way the real link does (after 60 s,
/// an answer or a conflict) and raise each `PairingEvent`, which `Loopback` does not model.
@MainActor final class FakeMacLink: MacLink {
    var pairingOpen = false {
        didSet { if pairingOpen != oldValue { onChange?() } }
    }
    var connectedDevice: String?
    var pairedPhones: [PairedPhone] = [] {
        didSet { onChange?() }
    }
    var onChange: (@MainActor () -> Void)?
    var onPairing: (@MainActor (PairingEvent) -> Void)?
    var onMessage: (@MainActor (PhoneToMac) -> Void)?
    private(set) var sent: [MacToPhone] = []
    private(set) var removed: [String] = []

    func start() {}

    func send(_ message: MacToPhone) { sent.append(message) }

    func remove(_ phoneID: String) {
        removed.append(phoneID)
        pairedPhones.removeAll { $0.id == phoneID }
    }

    /// The link shutting the window itself.
    func closePairing() { pairingOpen = false }

    /// A phone asks. `answers` collects what the user's click sent back.
    func ask(_ name: String = "Pat's iPhone") -> Asked {
        let asked = Asked()
        let request = PairingRequest(deviceName: name) { allow in asked.answers.append(allow) }
        asked.request = request
        onPairing?(.request(request))
        return asked
    }

    func raise(_ event: PairingEvent) { onPairing?(event) }

    @MainActor final class Asked {
        var request: PairingRequest!
        var answers: [Bool] = []
    }
}

extension PairedPhone {
    static func named(_ name: String, id: String = UUID().uuidString) -> PairedPhone {
        PairedPhone(id: id, name: name, pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
