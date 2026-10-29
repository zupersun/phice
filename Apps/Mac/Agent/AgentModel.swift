import Foundation
import Observation
import PhiceNet

/// What the setup window shows.
@MainActor @Observable final class AgentModel {
    var connectedDevice: String?
    var accessibilityGranted = false
    /// A phone is waiting for Allow or Don't Allow.
    var pairingRequest: PairingRequest?
    var loginItemEnabled = false
    var loginItemNote: String?
    let macName = Host.current().localizedName ?? "This Mac"
}
