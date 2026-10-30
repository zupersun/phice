import CryptoKit
import Foundation
import PhiceCore
import Testing
@testable import PhiceNet

@MainActor @Test func anUnknownIdentityOrAWrongKeyFailsTheHandshake() async {
    let rig = Rig()
    rig.seedKeys()
    #expect(await rig.start())

    let stranger = RawClient(port: rig.mac.port!, identity: UUID().uuidString, key: randomKey())
    let impostor = RawClient(port: rig.mac.port!, identity: rig.phoneStore.localID, key: randomKey())
    #expect(await eventually { stranger.refused && impostor.refused })
    #expect(rig.mac.connectedDevice == nil)
}

@MainActor @Test func thePairingKeyIsRefusedWhilePairingIsClosed() async {
    let rig = Rig()
    #expect(await rig.start())
    let newcomer = RawClient(port: rig.mac.port!, identity: Pairing.identity)
    #expect(await eventually { newcomer.refused })
}

@MainActor @Test func nothingIsDeliveredBeforeAuthentication() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    #expect(await rig.start())

    let plain = RawClient(port: rig.mac.port!, identity: nil)
    let newcomer = RawClient(port: rig.mac.port!, identity: Pairing.identity)
    #expect(await eventually { plain.ready && newcomer.ready })
    plain.send(.hello(deviceName: "Plain", appVersion: "1"))
    newcomer.send(.hello(deviceName: "Newcomer", appVersion: "1"))
    newcomer.send(.enabled(true))
    #expect(await eventually { plain.ended && newcomer.ended })
    #expect(rig.atMac.isEmpty)
    #expect(rig.requests.isEmpty)
    #expect(rig.mac.connectedDevice == nil)
}

@MainActor @Test(arguments: [Data([0, 0, 0, 3]) + Data("abc".utf8), Data([0x7F, 0xFF, 0xFF, 0xFF])])
func aBadFrameDropsTheConnection(frame: Data) async {
    let rig = Rig()
    let phoneID = UUID().uuidString
    let key = randomKey()
    rig.macStore.setKey(key, for: phoneID)
    #expect(await rig.start())

    let client = RawClient(port: rig.mac.port!, identity: phoneID, key: key)
    #expect(await eventually { client.ready })
    client.send(.hello(deviceName: "Raw", appVersion: "1"))
    #expect(await eventually { rig.mac.connectedDevice == "Raw" })
    client.send(frame)
    client.send(.enabled(true))
    #expect(await eventually { client.ended && rig.mac.connectedDevice == nil })
    #expect(rig.atMac == [.hello(deviceName: "Raw", appVersion: "1")])
}

@MainActor @Test func aSilentPhoneIsDroppedAtTheDeadline() async {
    let rig = Rig()
    let phoneID = UUID().uuidString
    let key = randomKey()
    rig.macStore.setKey(key, for: phoneID)
    #expect(await rig.start())

    let client = RawClient(port: rig.mac.port!, identity: phoneID, key: key)
    #expect(await eventually { client.ready })
    // Timed from before the hello, never from noticing it: under a busy suite the test can notice
    // late, and the drop, which is due 500 ms after the hello arrives, then looks early.
    let quietSince = ContinuousClock.now
    client.send(.hello(deviceName: "Raw", appVersion: "1"))
    #expect(await eventually { rig.mac.connectedDevice == "Raw" })
    #expect(await eventually { client.ended && rig.mac.connectedDevice == nil })
    #expect(ContinuousClock.now - quietSince >= .milliseconds(500))
}

@Test func bothSidesDeriveOneKeyAndTheProofBindsTheTranscript() throws {
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let mac = Curve25519.KeyAgreement.PrivateKey()
    func transcript(_ deviceName: String) -> Data {
        Pairing.transcript(phoneID: "phone", deviceName: deviceName,
                           phoneKey: phone.publicKey.rawRepresentation,
                           macID: "mac", macKey: mac.publicKey.rawRepresentation)
    }
    let named = transcript("iPhone")
    let atPhone = try Pairing.psk(phone, peer: mac.publicKey.rawRepresentation, transcript: named)
    let atMac = try Pairing.psk(mac, peer: phone.publicKey.rawRepresentation, transcript: named)
    #expect(atPhone == atMac)
    #expect(atPhone.count == 32)

    let proof = Pairing.proof(psk: atMac, transcript: transcript("iPhone"))
    #expect(Pairing.verify(proof, psk: atPhone, transcript: transcript("iPhone")))
    #expect(!Pairing.verify(proof, psk: atPhone, transcript: transcript("Someone else")))
    #expect(!Pairing.verify(proof, psk: randomKey(), transcript: transcript("iPhone")))
}

/// Network.framework can race one connection over several paths and drop the losers, so the Mac may
/// see a second authenticated connection that never speaks. It must not replace the phone.
@MainActor @Test func aSilentDuplicateDoesNotReplaceThePhone() async {
    let rig = Rig()
    let phoneID = UUID().uuidString
    let key = randomKey()
    rig.macStore.setKey(key, for: phoneID)
    #expect(await rig.start())

    let phone = RawClient(port: rig.mac.port!, identity: phoneID, key: key)
    phone.send(.hello(deviceName: "Phone", appVersion: "1"))
    #expect(await eventually { rig.mac.connectedDevice == "Phone" })
    let duplicate = RawClient(port: rig.mac.port!, identity: phoneID, key: key)
    #expect(await eventually { duplicate.ready })
    for _ in 0 ..< 10 {  // past the duplicate's deadline, the phone heartbeating throughout
        phone.send(.heartbeat)
        try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(duplicate.ended)
    #expect(!phone.ended)
    #expect(rig.macChanges == ["Phone"])
}
