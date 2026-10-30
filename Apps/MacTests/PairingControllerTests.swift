import AppKit
import Foundation
import PhiceCore
import PhiceNet
import Testing
@testable import Phice

@MainActor private struct LinkRig {
    let link = FakeMacLink()
    let agent: AgentController
    let pasteboard = NSPasteboard.withUniqueName()
    let windowRequests = Counter()

    init(autoAllow: Bool = false) {
        let clipboard = Clipboard(pasteboard: pasteboard, store: ClipStore(directory: tempDirectory()))
        agent = AgentController(
            link: link, poster: FakePoster(), clipboard: clipboard, directory: tempDirectory(),
            shortcuts: { [] }, accessibility: { true }, clock: { 0 }, autoAllow: autoAllow)
        let counter = windowRequests
        agent.onNeedsWindow = { counter.count += 1 }
        agent.start()
    }
}

@MainActor private final class Counter {
    var count = 0
}

private let withdrawnNote = "The iPhone stopped asking. Click Pair New iPhone to try again."
private let conflictNote = "Two devices asked to pair at the same time, so both were refused. "
    + "If only one was yours, someone nearby tried to pair. Try again."

// MARK: The window

@Test @MainActor func pairingOpensOnlyFromTheButton() {
    let rig = LinkRig()
    #expect(!rig.link.pairingOpen)
    #expect(!rig.agent.model.pairingOpen)

    rig.agent.startPairing()
    #expect(rig.link.pairingOpen)
    #expect(rig.agent.model.pairingOpen)
    #expect(rig.agent.model.pairingDeadline != nil)

    rig.agent.cancelPairing()
    #expect(!rig.link.pairingOpen)
    #expect(!rig.agent.model.pairingOpen)
    #expect(rig.agent.model.pairingDeadline == nil)
}

@Test @MainActor func whenTheLinkClosesPairingTheWaitEnds() {
    let rig = LinkRig()
    rig.agent.startPairing()
    rig.link.closePairing()    // 60 s, an answer, or a conflict
    #expect(!rig.agent.model.pairingOpen)
    #expect(rig.agent.model.pairingDeadline == nil)
}

@Test @MainActor func theCountdownRoundsUpAndStopsAtZero() {
    let model = AgentModel()
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(model.pairingSecondsLeft(now: start) == nil)
    model.pairingDeadline = start.addingTimeInterval(60)
    #expect(model.pairingSecondsLeft(now: start) == 60)
    #expect(model.pairingSecondsLeft(now: start.addingTimeInterval(59.2)) == 1)
    #expect(model.pairingSecondsLeft(now: start.addingTimeInterval(75)) == 0)
}

// MARK: The Allow alert

@Test @MainActor func aRequestIsShownAndTheWindowComesForward() {
    let rig = LinkRig()
    let asked = rig.link.ask("Pat's iPhone")
    #expect(rig.agent.model.pairingRequest?.id == asked.request.id)
    #expect(rig.windowRequests.count == 1)
}

@Test @MainActor func onlyTheRequestTheAlertWasOpenedWithIsAnswered() {
    let rig = LinkRig()
    let shown = rig.link.ask("Pat's iPhone")
    let stale = rig.link.ask("Someone else")   // refused below; never what the alert shows
    rig.agent.resolvePairing(stale.request, allow: true)
    #expect(stale.answers == [false])           // only the refusal when it arrived
    #expect(shown.answers.isEmpty)
    #expect(rig.agent.model.pairingRequest?.id == shown.request.id)

    rig.agent.resolvePairing(shown.request, allow: true)
    #expect(shown.answers == [true])
    #expect(rig.agent.model.pairingRequest == nil)
}

@Test @MainActor func aSecondRequestNeverReplacesTheOneOnScreen() {
    let rig = LinkRig()
    let first = rig.link.ask("First")
    let second = rig.link.ask("Second")
    #expect(rig.agent.model.pairingRequest?.id == first.request.id)
    #expect(second.answers == [false])
    #expect(first.answers.isEmpty)
}

@Test @MainActor func aWithdrawnRequestDismissesTheAlertAndSaysSo() {
    let rig = LinkRig()
    rig.link.raise(.withdrawn)                 // nothing on screen: nothing to explain
    #expect(rig.agent.model.pairingNote == nil)

    let asked = rig.link.ask()
    rig.link.raise(.withdrawn)
    #expect(rig.agent.model.pairingRequest == nil)
    #expect(rig.agent.model.pairingNote == withdrawnNote)
    #expect(asked.answers.isEmpty)             // the link refused it; the UI sends nothing more
}

@Test @MainActor func aConflictDismissesTheAlertAndWarns() {
    let rig = LinkRig()
    _ = rig.link.ask()
    let before = rig.windowRequests.count
    rig.link.raise(.conflict)
    #expect(rig.agent.model.pairingRequest == nil)
    #expect(rig.agent.model.pairingNote == conflictNote)
    #expect(rig.windowRequests.count == before + 1)
}

@Test @MainActor func startingAgainClearsTheOldNote() {
    let rig = LinkRig()
    rig.link.raise(.conflict)
    #expect(rig.agent.model.pairingNote != nil)
    rig.agent.startPairing()
    #expect(rig.agent.model.pairingNote == nil)
}

@Test @MainActor func youCannotStartPairingUnderAnOpenAlert() {
    let rig = LinkRig()
    _ = rig.link.ask()
    rig.agent.startPairing()
    #expect(!rig.link.pairingOpen)
}

// MARK: Paired iPhones

@Test @MainActor func pairedPhonesMirrorTheLinkAndRemoveGoesThroughIt() {
    let rig = LinkRig()
    #expect(rig.agent.model.pairedPhones.isEmpty)
    let pat = PairedPhone.named("Pat's iPhone"), sam = PairedPhone.named("Sam's iPhone")
    rig.link.pairedPhones = [pat, sam]
    #expect(rig.agent.model.pairedPhones == [pat, sam])

    rig.agent.remove(pat)
    #expect(rig.link.removed == [pat.id])
    #expect(rig.agent.model.pairedPhones == [sam])
}

// MARK: Clipboard

@Test @MainActor func nothingIsCapturedWhileNoPhoneIsPaired() {
    let rig = LinkRig()
    rig.pasteboard.clearContents()
    rig.pasteboard.setString("copied before pairing", forType: .string)
    rig.agent.housekeep()
    #expect(rig.agent.clipboard.store.history.isEmpty)

    rig.link.pairedPhones = [.named("Pat's iPhone")]
    rig.agent.housekeep()                      // the earlier copy is not swept in afterwards
    #expect(rig.agent.clipboard.store.history.isEmpty)

    rig.pasteboard.clearContents()
    rig.pasteboard.setString("copied after pairing", forType: .string)
    rig.agent.housekeep()
    #expect(rig.agent.clipboard.store.history.map(\.preview) == ["copied after pairing"])
}

#if DEBUG
@Test @MainActor func autoAllowReopensPairingWhenTheLinkClosesIt() {
    let rig = LinkRig(autoAllow: true)
    #expect(rig.link.pairingOpen)
    rig.link.closePairing()
    #expect(rig.link.pairingOpen)
    rig.agent.cancelPairing()                  // closing the window does not close it either
    #expect(rig.link.pairingOpen)
}
#endif
