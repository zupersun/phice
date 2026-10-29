import PhiceCore
import Testing
@testable import PhiceNet

@MainActor private final class Inbox {
    var messages: [PhoneToMac] = []
}

@MainActor @Test func pairsOnAllowThenDeliversMessages() async {
    let (phone, mac) = Loopback.pair()
    let inbox = Inbox()
    mac.pairingOpen = true
    mac.onPairingRequest = { $0.respond(true) }
    mac.onMessage = { inbox.messages.append($0) }

    phone.start()
    #expect(phone.macs.first?.pairingOpen == true)
    phone.pair(with: phone.macs[0])
    #expect(phone.state == .connected)
    #expect(mac.connectedDevice == "Loopback iPhone")

    phone.send(.heartbeat)
    for _ in 0 ..< 10 where inbox.messages.isEmpty { await Task.yield() }
    #expect(inbox.messages == [.heartbeat])
}

@MainActor @Test func nothingIsDeliveredWhenTheMacSaysNo() async {
    let (phone, mac) = Loopback.pair()
    let inbox = Inbox()
    mac.onPairingRequest = { $0.respond(false) }
    mac.onMessage = { inbox.messages.append($0) }

    phone.start()
    phone.pair(with: phone.macs[0])
    phone.send(.heartbeat)
    for _ in 0 ..< 10 { await Task.yield() }
    #expect(phone.state == .searching)
    #expect(inbox.messages.isEmpty)
}
