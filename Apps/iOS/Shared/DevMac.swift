import PhiceCore
import PhiceNet

/// Stands in for the Mac until the real link is wired in: accepts pairing and says hello.
@MainActor final class DevMac {
    let mac: LoopbackMacLink

    init(mac: LoopbackMacLink) {
        self.mac = mac
        mac.pairingOpen = true
        mac.onPairingRequest = { [weak mac] request in
            request.respond(true)
            mac?.send(.hello(macName: "Simulator Mac", settings: TrackpadSettings()))
        }
    }
}
