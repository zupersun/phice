import Foundation
import Observation
import PhiceNet

/// What the setup window shows.
@MainActor @Observable final class AgentModel {
    var connectedDevice: String?
    var accessibilityGranted = false
    /// A phone is waiting for Allow or Don't Allow. The alert is bound to this request's id.
    var pairingRequest: PairingRequest?
    /// A new phone may pair right now (mirrors the link, which closes it itself).
    var pairingOpen = false
    /// When the link will close pairing, for the countdown.
    var pairingDeadline: Date?
    /// Why the last attempt ended without a phone, or nil.
    var pairingNote: String?
    var pairedPhones: [PairedPhone] = []
    var loginItemEnabled = false
    var loginItemNote: String?
    let macName = Host.current().localizedName ?? "This Mac"

    /// Whole seconds left, rounded up, never negative; nil when pairing is not open.
    func pairingSecondsLeft(now: Date) -> Int? {
        pairingDeadline.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }
}
