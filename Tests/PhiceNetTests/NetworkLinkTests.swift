import Foundation
import PhiceCore
import Testing
@testable import PhiceNet

@MainActor @Test func allowPairsThenCarriesMessagesBothWays() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    rig.mac.onPairingRequest = { [rig] in
        rig.requests.append($0.deviceName)
        $0.respond(true)
    }
    #expect(await rig.start())
    rig.showMac(pairingOpen: true)
    #expect(rig.phone.macs.map(\.paired) == [false])

    rig.phone.pair(with: rig.phone.macs[0])
    #expect(rig.phone.state == .pairing)
    #expect(await eventually { rig.phone.state == .connected })
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })
    #expect(rig.requests == ["Test iPhone"])
    #expect(rig.phone.macs.map(\.paired) == [true])
    let key = rig.phoneStore.key(for: rig.macStore.localID)
    #expect(key?.count == 32)
    #expect(key == rig.macStore.key(for: rig.phoneStore.localID))
    guard case .hello("Test iPhone", _)? = rig.atMac.first else {
        Issue.record("the first message was \(String(describing: rig.atMac.first)), not hello")
        return
    }

    rig.phone.send(.enabled(false))
    rig.mac.send(.dropResult(ok: true))
    #expect(await eventually { rig.atMac.contains(.enabled(false)) })
    #expect(await eventually { rig.atPhone == [.dropResult(ok: true)] })
}

@MainActor @Test func dontAllowStoresNothingAndDeliversNothing() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    rig.mac.onPairingRequest = { [rig] in
        rig.requests.append($0.deviceName)
        $0.respond(false)
    }
    #expect(await rig.start())
    rig.showMac(pairingOpen: true)

    rig.phone.pair(with: rig.phone.macs[0])
    #expect(await eventually { rig.requests.count == 1 && rig.phone.state == .searching })
    rig.phone.send(.enabled(true))
    try? await Task.sleep(for: .milliseconds(200))
    #expect(rig.atMac.isEmpty)
    #expect(rig.mac.connectedDevice == nil)
    #expect(rig.phoneStore.peers.isEmpty && rig.macStore.peers.isEmpty)
}

@MainActor @Test func aMacWithPairingClosedRefusesANewPhone() async {
    let rig = Rig()
    rig.mac.onPairingRequest = { [rig] in rig.requests.append($0.deviceName) }
    #expect(await rig.start())
    // The phone believes the flag; the Mac does not.
    rig.showMac(pairingOpen: true)

    rig.phone.pair(with: rig.phone.macs[0])
    #expect(await eventually { rig.phone.state == .searching })
    #expect(rig.requests.isEmpty)
    #expect(rig.phoneStore.peers.isEmpty)
}

@MainActor @Test func aStoredKeyReconnectsAfterTheConnectionDrops() async {
    let rig = Rig()
    rig.seedKeys()
    let otherID = UUID().uuidString
    let otherKey = randomKey()
    rig.macStore.setKey(otherKey, for: otherID)
    #expect(await rig.start())
    rig.showMac()
    #expect(await eventually { rig.phone.state == .connected })
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })

    // Another paired phone takes over, which drops this one; it comes straight back and wins.
    let other = RawClient(port: rig.mac.port!, identity: otherID, key: otherKey)
    #expect(await eventually { other.ready })
    other.send(.hello(deviceName: "Other", appVersion: "1"))
    #expect(await eventually { other.ended })
    #expect(await eventually { rig.phone.state == .connected })
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })
    #expect(rig.atMac.filter { $0 == .hello(deviceName: "Other", appVersion: "1") }.count == 1)
    #expect(rig.hellos == 3)
}

@MainActor @Test func heartbeatsKeepAQuietLinkAlive() async {
    let rig = Rig()
    rig.seedKeys()
    #expect(await rig.start())
    rig.showMac()
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })

    try? await Task.sleep(for: .milliseconds(1500))  // three times the deadline
    #expect(rig.phone.state == .connected)
    #expect(rig.mac.connectedDevice == "Test iPhone")
    #expect(rig.hellos == 1)
    #expect(rig.atMac.filter { $0 == .heartbeat }.count >= 10)
}

@MainActor @Test func forgetDropsTheKeyAndTheConnection() async {
    let rig = Rig()
    rig.seedKeys()
    #expect(await rig.start())
    rig.showMac()
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })

    rig.phone.forget()
    #expect(rig.phone.state == .searching)
    #expect(rig.phoneStore.peers.isEmpty)
    #expect(rig.phone.macs.map(\.paired) == [false])
    #expect(await eventually { rig.mac.connectedDevice == nil })
    try? await Task.sleep(for: .milliseconds(300))
    #expect(rig.phone.state == .searching)
    #expect(rig.hellos == 1)
    #expect(rig.macChanges == ["Test iPhone", nil])
}

@MainActor @Test func aPairedMacOutOfSightIsUnreachableUntilSeen() async {
    let rig = Rig()
    rig.seedKeys()
    #expect(await rig.start())
    #expect(rig.phone.state == .searching)
    #expect(await eventually { rig.phone.state == .unreachable })

    rig.showMac()
    #expect(await eventually { rig.phone.state == .connected })
}

@MainActor @Test func theMacAnnouncesEveryChangeOfConnectedDeviceAndPairing() async {
    let rig = Rig()
    let (first, second) = ((UUID().uuidString, randomKey()), (UUID().uuidString, randomKey()))
    rig.macStore.setKey(first.1, for: first.0)
    rig.macStore.setKey(second.1, for: second.0)
    rig.mac.pairingOpen = true
    rig.mac.pairingOpen = false
    #expect(rig.macChanges == [nil, nil])
    #expect(await rig.start())

    let a = RawClient(port: rig.mac.port!, identity: first.0, key: first.1)
    a.send(.hello(deviceName: "Phone", appVersion: "1"))
    #expect(await eventually { rig.mac.connectedDevice == "Phone" })
    // The same name again: the app still has to hear that a new connection replaced the old one.
    let b = RawClient(port: rig.mac.port!, identity: second.0, key: second.1)
    b.send(.hello(deviceName: "Phone", appVersion: "1"))
    #expect(await eventually { a.ended && rig.macChanges.count == 5 })
    b.connection.cancel()
    #expect(await eventually { rig.mac.connectedDevice == nil })
    #expect(rig.macChanges == [nil, nil, "Phone", nil, "Phone", nil])
}
