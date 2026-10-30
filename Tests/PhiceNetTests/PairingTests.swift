import Foundation
import Network
import PhiceCore
import Testing
@testable import PhiceNet

/// The attacker connects the moment pairing opens and names itself like the user's phone. When the
/// real phone asks too, neither gets in: both are refused, the window closes, and the Mac says so.
@MainActor @Test func anAttackerFirstMakesAConflictInsteadOfLockingOutThePhone() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    #expect(await rig.start())

    let attacker = PairingClient(port: rig.mac.port!)
    #expect(await eventually { attacker.state == .ready })
    attacker.request(name: "Test iPhone")
    #expect(await eventually { rig.events == ["request Test iPhone"] })

    rig.showMac(pairingOpen: true)
    rig.phone.pair(with: rig.phone.macs[0])
    #expect(await eventually { rig.events == ["request Test iPhone", "conflict"] })
    #expect(!rig.mac.pairingOpen)
    #expect(await eventually { attacker.answers == [.refuse] })
    #expect(await eventually { rig.phone.state == .searching })
    rig.shown[0].respond(true)  // too late: the conflict refused it
    try? await Task.sleep(for: .milliseconds(200))
    #expect(rig.macStore.peers.isEmpty)
    #expect(rig.phoneStore.peers.isEmpty)
}

/// A request whose phone leaves is withdrawn at once and closes the window, so nobody can step in
/// after it; answering it does nothing, and pairing again takes the window reopened.
@MainActor @Test func aVanishedRequestIsWithdrawnAndClosesTheWindow() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    #expect(await rig.start())

    let gone = PairingClient(port: rig.mac.port!)
    #expect(await eventually { gone.state == .ready })
    gone.request(name: "iPhone")
    #expect(await eventually { rig.events == ["request iPhone"] })
    gone.connection.cancel()  // the phone went to the background
    #expect(await eventually { rig.events == ["request iPhone", "withdrawn"] })
    #expect(!rig.mac.pairingOpen)

    let intruder = PairingClient(port: rig.mac.port!)
    #expect(await eventually { intruder.refused })
    rig.shown[0].respond(true)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(rig.shown.count == 1)
    #expect(rig.macStore.peers.isEmpty)

    rig.mac.pairingOpen = true  // the user presses Pair New iPhone again
    let next = PairingClient(port: rig.mac.port!)
    #expect(await eventually { next.state == .ready })
    next.request(name: "iPhone")
    #expect(await eventually { rig.shown.count == 2 })
    #expect(rig.shown[0].id != rig.shown[1].id)
    rig.shown[1].respond(true)
    #expect(await eventually { rig.macStore.peers == [next.phoneID] })
}

/// A pairing connection lasts no longer than the window however it trickles bytes: inbound data
/// does not buy time. The window keeps its full length here and is ended as the timer ends it, so
/// nothing races the setup (a 1 s window once ran out under a busy suite before the request came).
@MainActor @Test func aPairingConnectionLastsNoLongerThanTheWindow() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    #expect(await rig.start())

    let waiting = PairingClient(port: rig.mac.port!)
    let trickler = PairingClient(port: rig.mac.port!)
    #expect(await eventually { waiting.state == .ready && trickler.state == .ready })
    waiting.request(name: "iPhone")
    #expect(await eventually { rig.events == ["request iPhone"] })
    trickler.connection.send(content: Data([0, 0, 0, 100]), completion: .idempotent)

    rig.mac.pairingOpen = false
    // A frame that never completes, a byte at a time: enough to keep any idle limit at bay.
    for _ in 0 ..< 20 where !trickler.ended {
        trickler.connection.send(content: Data([0x20]), completion: .idempotent)
        try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(trickler.ended)
    #expect(rig.events == ["request iPhone", "withdrawn"])
    #expect(await eventually { waiting.answers == [.refuse] })
}

/// The window closes by itself. Nothing else happens in this test, so there is nothing to race.
@MainActor @Test func thePairingWindowClosesByItself() async {
    var timing = LinkTiming.fast
    timing.pairingWindow = .milliseconds(300)
    let rig = Rig(timing: timing)
    #expect(await rig.start())
    rig.mac.pairingOpen = true
    #expect(rig.mac.pairingOpen)
    #expect(await eventually { !rig.mac.pairingOpen })
    #expect(rig.macChanges.count == 2)
}

/// Only four pairing handshakes at a time, and a flood of them never disturbs a paired phone's own.
@MainActor @Test func aFloodOfPairingHandshakesCannotCrowdOutAPairedPhone() async {
    let rig = Rig()
    rig.seedKeys()
    rig.mac.pairingOpen = true
    #expect(await rig.start())

    let flood = (0 ..< 40).map { _ in PairingClient(port: rig.mac.port!) }
    rig.showMac()
    #expect(await eventually { rig.phone.state == .connected })
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })
    try? await Task.sleep(for: .milliseconds(300))  // every handshake settled
    #expect(flood.filter { $0.state == .ready }.count <= 4)
}

/// A request never replaces a key the Mac already holds, so it cannot take over a paired phone.
@MainActor @Test func aRequestCannotReplaceAPairedPhonesKey() async {
    let rig = Rig()
    let phoneID = UUID().uuidString
    let key = randomKey()
    rig.macStore.setKey(key, label: "Real iPhone", for: phoneID)
    rig.mac.pairingOpen = true
    rig.autoAnswer = true
    #expect(await rig.start())

    let impostor = PairingClient(port: rig.mac.port!, phoneID: phoneID)
    #expect(await eventually { impostor.state == .ready })
    impostor.request(name: "Real iPhone")
    #expect(await eventually { impostor.ended })
    #expect(rig.events.isEmpty)
    #expect(rig.macStore.key(for: phoneID) == key)
}

/// Each pairing takes a fresh phone id, so pairing again adds a phone instead of replacing one;
/// the old one stays listed until removed, and removing the current one drops it.
@MainActor @Test func pairingAgainAddsAPhoneAndRemoveTakesOneAway() async {
    let rig = Rig()
    rig.autoAnswer = true
    #expect(await rig.start())
    for round in 1 ... 2 {
        rig.mac.pairingOpen = true
        rig.showMac(pairingOpen: true)
        rig.phone.pair(with: rig.phone.macs[0])
        #expect(await eventually { rig.mac.pairedPhones.count == round })
        #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })
    }
    let current = rig.phoneStore.entry(for: rig.macStore.localID)!.label
    let old = rig.mac.pairedPhones.map(\.id).filter { $0 != current }
    #expect(old.count == 1)

    let changes = rig.macChanges.count
    rig.mac.remove(current)
    #expect(rig.mac.pairedPhones.map(\.id) == old)
    #expect(rig.macChanges.count > changes)
    #expect(await eventually { rig.mac.connectedDevice == nil })
    try? await Task.sleep(for: .milliseconds(500))  // its reconnects are refused now
    #expect(rig.mac.connectedDevice == nil)
}

@Test(arguments: [
    ("Jasper’s iPhone", "Jasper’s iPhone"),
    ("\u{202E}enohPi", "enohPi"),  // a right-to-left override would flip the alert's text
    ("iPhone\u{0007}\u{2028}\u{2029}\n", "iPhone"),
    ("\u{200B}\u{200D}", "iPhone"),  // nothing visible left
    ("   ", "iPhone"),
    (String(repeating: "x", count: 40), String(repeating: "x", count: 32)),
])
func namesArePlainAndShort(raw: String, shown: String) {
    #expect(Pairing.displayName(raw) == shown)
}

/// The name in the alert, the one kept with the key and the one in `hello` are all cleaned; the
/// key itself still binds the name the phone actually sent.
@MainActor @Test func theMacShowsAndKeepsOnlyCleanNames() async {
    let rig = Rig()
    rig.mac.pairingOpen = true
    rig.autoAnswer = true
    #expect(await rig.start())

    let raw = "\u{202E}Evil\u{0000}"
    let client = PairingClient(port: rig.mac.port!)
    #expect(await eventually { client.state == .ready })
    client.request(name: raw)
    #expect(await eventually { rig.requests == ["Evil"] })
    #expect(await eventually { rig.mac.pairedPhones.map(\.name) == ["Evil"] })
    #expect(await eventually { client.answers.count == 1 })

    let session = RawClient(port: rig.mac.port!, identity: client.phoneID, key: client.psk(name: raw)!)
    session.send(.hello(deviceName: "\u{202E}Evil\u{0007}", appVersion: "1"))
    #expect(await eventually { rig.mac.connectedDevice == "Evil" })
}

/// A Mac advertising another Mac's id cannot hide it: the phone tries every endpoint seen for an id.
@MainActor @Test func aSpoofedIDCannotShadowThePairedMac() async {
    let rig = Rig()
    rig.seedKeys()
    let impostor = SilentMac(phoneID: UUID().uuidString, key: randomKey())  // holds none of our keys
    #expect(await eventually { impostor.port != nil })
    #expect(await rig.start())
    rig.phone.see([
        Sighting(id: rig.macStore.localID, name: "Test Mac", pairingOpen: false,
                 endpoint: .hostPort(host: "127.0.0.1", port: impostor.port!)),
        Sighting(id: rig.macStore.localID, name: "Test Mac", pairingOpen: false,
                 endpoint: .hostPort(host: "127.0.0.1", port: rig.mac.port!)),
    ])
    #expect(await eventually { rig.phone.state == .connected })
    #expect(await eventually { rig.mac.connectedDevice == "Test iPhone" })
}
