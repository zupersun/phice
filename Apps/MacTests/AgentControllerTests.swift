import AppKit
import Foundation
import PhiceCore
import PhiceNet
import Testing
@testable import Phice

@MainActor private struct Rig {
    let agent: AgentController
    let phone: LoopbackPhoneLink
    let mac: LoopbackMacLink
    let poster = FakePoster()
    let directory = tempDirectory()
    let pasteboard = NSPasteboard.withUniqueName()
    let received = Inbox()
    let access = Flag(true)

    init(shortcuts: [String] = ["Resize", "Upload"], autoAllow: Bool = false) {
        (phone, mac) = Loopback.pair()
        let clipboard = Clipboard(pasteboard: pasteboard, store: ClipStore(directory: directory))
        let access = access
        agent = AgentController(
            link: mac, poster: poster, clipboard: clipboard, directory: directory,
            shortcuts: { shortcuts }, accessibility: { access.value }, clock: { 0 },
            autoAllow: autoAllow)
        let inbox = received
        phone.onMessage = { inbox.messages.append($0) }
    }

    /// The whole pairing dance, as the phone and the Allow dialog would run it.
    func connect() async {
        agent.start()
        phone.start()
        phone.pair(with: phone.macs[0])
        agent.model.pairingRequest?.respond(true)
        await settle()
    }
}

@MainActor private final class Inbox {
    var messages: [MacToPhone] = []
}

private final class Flag: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor private func settle() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func aNewPhoneIsAskedAboutBeforeItIsAllowed() async {
    let rig = Rig()
    var windowOpened = false
    rig.agent.onNeedsWindow = { windowOpened = true }
    rig.agent.start()
    rig.phone.start()
    rig.phone.pair(with: rig.phone.macs[0])
    #expect(rig.agent.model.pairingRequest?.deviceName == "Loopback iPhone")
    #expect(windowOpened)
    #expect(rig.agent.model.connectedDevice == nil)
    rig.agent.model.pairingRequest?.respond(true)
    await settle()
    #expect(rig.agent.model.connectedDevice == "Loopback iPhone")
}

@Test @MainActor func connectingSendsEverythingThePhoneNeeds() async {
    let rig = Rig()
    await rig.connect()
    let m = rig.received.messages
    guard case .hello(let name, let settings) = m.first else { Issue.record("no hello"); return }
    #expect(!name.isEmpty)
    #expect((0...3).contains(settings.trackingSpeed))
    #expect(m.contains(.state(accessibility: true)))
    #expect(m.contains(.clipboard([])))
    #expect(m.contains(.pill(nil)))
    #expect(m.contains(.shortcuts(["Resize", "Upload"])))
}

@Test @MainActor func accessibilityChangesAreReportedOnce() async {
    let rig = Rig()
    await rig.connect()
    rig.received.messages.removeAll()
    rig.access.value = false
    rig.agent.refreshAccessibility()
    rig.agent.refreshAccessibility()
    await settle()
    #expect(rig.received.messages == [.state(accessibility: false)])
    #expect(!rig.agent.model.accessibilityGranted)
}

@Test @MainActor func clipboardAndPillChangesArePushedWhileConnected() async throws {
    let rig = Rig()
    await rig.connect()
    rig.received.messages.removeAll()
    let item = try #require(rig.agent.clipboard.store.add(text("dropped"), asPill: true))
    await settle()
    #expect(rig.received.messages.contains(.clipboard([item])))
    #expect(rig.received.messages.contains(.pill(item)))
}

@Test @MainActor func nothingIsSentWithoutAPhone() async {
    let rig = Rig()
    rig.agent.start()
    rig.agent.clipboard.store.add(text("alone"), now: Date())
    await settle()
    #expect(rig.received.messages.isEmpty)
}

@Test @MainActor func recordingWritesOneJSONLineForEveryFrame() async throws {
    let rig = Rig()
    await rig.connect()
    let frame = TouchFrame(t: 1, touches: [
        Touch(id: 1, x: 10, y: 20, radius: 6, phase: .began, t: 1),
    ])
    rig.phone.send(.frames([frame]))        // not recording yet: dropped
    rig.phone.send(.record(true))
    await settle()
    rig.phone.send(.frames([frame, frame]))
    rig.phone.send(.record(false))
    rig.phone.send(.frames([frame]))        // stopped again: dropped
    await settle()

    let folder = rig.directory.appendingPathComponent("recordings")
    let files = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(files[0].pathExtension == "jsonl")
    let lines = try String(contentsOf: files[0], encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(try JSONDecoder().decode(TouchFrame.self, from: Data(lines[0].utf8)) == frame)
}

@Test func theFakePosterFlagSwapsTheRealOne() {
    let clipboard = Clipboard(pasteboard: .withUniqueName(),
                              store: ClipStore(directory: tempDirectory()))
    func poster(_ arguments: [String]) -> any EventPoster {
        AgentController.makePoster(LaunchOptions(arguments: arguments), clipboard: clipboard)
    }
    let log = tempDirectory().appendingPathComponent("calls.jsonl").path
    #expect(poster(["Phice", "--fake-poster"]) is FakePoster)
    #expect(poster(["Phice", "--fake-poster", log]) is LoggingPoster)
    #expect(poster(["Phice"]) is QuartzPoster)
}

#if DEBUG
@Test @MainActor func autoAllowAcceptsEveryPairingAndKeepsPairingOpen() async {
    let rig = Rig(autoAllow: true)
    rig.agent.start()
    #expect(rig.mac.pairingOpen)
    rig.agent.cancelPairing()                   // closing the window must not close pairing
    #expect(rig.mac.pairingOpen)
    rig.phone.start()
    rig.phone.pair(with: rig.phone.macs[0])
    await settle()
    #expect(rig.agent.model.pairingRequest == nil)
    #expect(rig.agent.model.connectedDevice == "Loopback iPhone")
}

// Any device nearby could have auto-paired, so a debug run must not hand it the clipboard.
@Test @MainActor func autoAllowNeverSendsTheClipboardToThePhone() async {
    let rig = Rig(autoAllow: true)
    rig.agent.clipboard.store.add(text("private"), asPill: true, now: Date())
    rig.agent.start()
    rig.phone.start()
    rig.phone.pair(with: rig.phone.macs[0])
    await settle()
    rig.agent.clipboard.store.add(text("copied while connected"), asPill: true, now: Date())
    await settle()
    let sent = rig.received.messages
    #expect(sent.contains(.clipboard([])))
    #expect(sent.contains(.pill(nil)))
    for message in sent {
        if case .clipboard(let items) = message { #expect(items.isEmpty) }
        if case .pill(let item) = message { #expect(item == nil) }
    }
}
#endif

@Test @MainActor func withoutAutoAllowPairingStillWaitsForTheUser() async {
    let rig = Rig()
    rig.agent.start()
    rig.phone.start()
    rig.phone.pair(with: rig.phone.macs[0])
    await settle()
    #expect(rig.agent.model.pairingRequest != nil)
    #expect(rig.agent.model.connectedDevice == nil)
}

@Test func theClipboardListFitsInAFrame() {
    let thumb = Data(repeating: 7, count: 30_000)
    let items = (0..<50).map {
        ClipItem(id: "\($0)", kind: .image, preview: "Image", thumbnail: thumb, date: Date())
    }
    let sent = ClipboardPayload.items(from: items)
    #expect(sent.count < 50)
    #expect(sent.first == items.first)
    let frame = try? FrameCodec.encode(MacToPhone.clipboard(sent))
    #expect((frame?.count ?? .max) < FrameCodec.maxFrame / 2)
}

@Test @MainActor func theAgentDoesNothingInsideTheTestHost() {
    #expect(AppEnvironment.isTesting)
    #expect(NSApp.windows.filter { $0.isVisible }.isEmpty)
}

@Test func aLoginItemLaunchIsToldApartFromAUserLaunch() {
    let launch = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
    #expect(!AppEnvironment.launchedAsLoginItem(launch))
    launch.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                    forKeyword: AEKeyword(keyAEPropData))
    #expect(AppEnvironment.launchedAsLoginItem(launch))
    #expect(!AppEnvironment.launchedAsLoginItem(nil))
}
