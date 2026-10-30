import AppKit
import CoreGraphics
import Foundation
import PhiceCore
import PhiceNet

/// Everything the agent does, with its parts handed in so a test can swap any of them. Messages
/// from the phone go to the driver and its replies go back; clipboard and permission changes are
/// pushed as they happen.
@MainActor final class AgentController {
    let model = AgentModel()
    let link: any MacLink
    let poster: any EventPoster
    let clipboard: Clipboard
    let driver: MacDriver
    /// A pairing request arrived while the window may be closed.
    var onNeedsWindow: (() -> Void)?

    private let shortcutList: @Sendable () async -> [String]
    private let accessibilityProbe: () -> Bool
    private let clock: () -> Double
    private let recorder: SessionRecorder
    /// Accept every pairing request without asking. Debug builds only, for end-to-end tests.
    private let autoAllow: Bool
    private var ticker: Timer?
    private var housekeeper: Timer?
    private var beats = 0
    private var busy: NSObjectProtocol?
    private var idleStop: Task<Void, Never>?

    init(link: any MacLink, poster: any EventPoster, clipboard: Clipboard, directory: URL,
         shortcuts: @escaping @Sendable () async -> [String], accessibility: @escaping () -> Bool,
         clock: @escaping () -> Double, autoAllow: Bool = false) {
        #if DEBUG
        self.autoAllow = autoAllow
        #else
        self.autoAllow = false   // the Allow click is the security boundary (constraint 7)
        #endif
        self.link = link
        self.poster = poster
        self.clipboard = clipboard
        shortcutList = shortcuts
        accessibilityProbe = accessibility
        self.clock = clock
        recorder = SessionRecorder(directory: directory)
        let curves = AccelCurveReader.read()
        driver = MacDriver(poster: poster, settings: TrackpadSettingsReader.current(),
                           curves: curves.pointer, scrollCurves: curves.scroll)
    }

    /// `--fake-poster [PATH]` stands in for the cursor, and logs what it was asked to do to PATH.
    nonisolated static func makePoster(_ options: LaunchOptions,
                                       clipboard: Clipboard) -> any EventPoster {
        guard options.fakePoster else { return QuartzPoster(clipboard: clipboard) }
        return options.fakePosterLog.map { LoggingPoster(log: $0) } ?? FakePoster()
    }

    static func live(arguments: [String]) -> AgentController {
        let options = LaunchOptions(arguments: arguments)
        let directory = AppEnvironment.supportDirectory
        let clipboard = Clipboard(store: ClipStore(directory: directory))
        return AgentController(
            link: LinkFactory.make(autoAllow: options.autoAllow),
            poster: makePoster(options, clipboard: clipboard),
            clipboard: clipboard, directory: directory,
            shortcuts: { await ShortcutsCLI.list() }, accessibility: { CGPreflightPostEventAccess() },
            clock: { ProcessInfo.processInfo.systemUptime }, autoAllow: options.autoAllow)
    }

    func start() {
        link.onChange = { [weak self] in self?.linkChanged() }
        link.onMessage = { [weak self] message in self?.receive(message) }
        link.onPairing = { [weak self] event in self?.pairing(event) }
        clipboard.store.onChange = { [weak self] in self?.pushClipboard() }
        refreshAccessibility()
        refreshLoginItem()
        housekeeper = schedule(every: 0.25) { $0.housekeep() }
        if autoAllow {
            NSLog("PHICE WARNING: --auto-allow is ON. Every pairing request is accepted unasked and "
                  + "pairing stays open: the Allow boundary (CLAUDE.md constraint 7) is disabled.")
            link.pairingOpen = true
        }
        link.start()
        syncLink()
    }

    // MARK: Messages

    private func receive(_ message: PhoneToMac) {
        switch message {
        case .record(let on): if on { recorder.start() } else { recorder.stop() }
        case .frames(let frames): recorder.append(frames)
        default: break
        }
        for reply in driver.handle(message, now: clock()) { send(reply) }
    }

    private func send(_ message: MacToPhone) {
        guard model.connectedDevice != nil else { return }
        link.send(message)
    }

    private func linkChanged() {
        syncLink()
        let device = link.connectedDevice
        guard device != model.connectedDevice else { return }
        model.connectedDevice = device
        if device == nil {
            recorder.stop()
            stopTickingSoon()
        } else {
            model.pairingRequest = nil
            beginTicking()
            greet()
        }
    }

    /// What a phone needs on connecting, so it can draw its Mac section, pill and column at once.
    private func greet() {
        send(.hello(macName: model.macName, settings: TrackpadSettingsReader.current()))
        send(.state(accessibility: model.accessibilityGranted))
        pushClipboard()
        Task {
            let names = await shortcutList()
            (poster as? QuartzPoster)?.allowedShortcuts = Set(names)
            send(.shortcuts(names))
        }
    }

    private func pushClipboard() {
        // Under --auto-allow any device in range may have paired itself; it gets none of this.
        send(.clipboard(autoAllow ? [] : ClipboardPayload.items(from: clipboard.store.history)))
        send(.pill(autoAllow ? nil : clipboard.store.pill))
    }

    // MARK: Clock

    /// Constraint 1: pending clicks, momentum and the silence timeout are all time-based, so the
    /// driver is ticked even when no message arrives. Only while a phone is there, and for a
    /// second after, to let the silence timeout release anything it held.
    private func beginTicking() {
        idleStop?.cancel()
        idleStop = nil
        guard ticker == nil else { return }
        // An agent with no window would be napped, and a napping timer cannot keep a cursor smooth.
        busy = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                     reason: "An iPhone is driving the cursor")
        ticker = schedule(every: 1.0 / 120) { $0.driver.tick(now: $0.clock()) }
    }

    private func stopTickingSoon() {
        idleStop = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            ticker?.invalidate()
            ticker = nil
            if let busy { ProcessInfo.processInfo.endActivity(busy) }
            busy = nil
        }
    }

    /// Four times a second: copies made on the Mac go to history. Every fourth beat the permission,
    /// and every hour the history's age, is checked.
    func housekeep() {
        // No phone has ever been allowed, so nothing of the clipboard is kept for one.
        if model.pairedPhones.isEmpty { clipboard.discardChanges() } else { clipboard.poll() }
        beats += 1
        if beats % 4 == 0 { refreshAccessibility() }
        if beats % 14_400 == 0 { clipboard.store.prune(now: Date()) }
    }

    private func schedule(every interval: TimeInterval,
                          _ work: @escaping @MainActor (AgentController) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { work(self) }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Window actions

    /// The link closes pairing itself after this long, after any answer, and on a conflict; this is
    /// only for the countdown.
    static let pairingWindow: TimeInterval = 60

    /// Constraint 7: pairing opens from the button and nothing else, never from opening the window.
    func startPairing() {
        guard model.pairingRequest == nil else { return }
        model.pairingNote = nil
        link.pairingOpen = true
        syncLink()
        if model.pairingOpen { model.pairingDeadline = Date().addingTimeInterval(Self.pairingWindow) }
    }

    /// Cancel, or the window closed. Under --auto-allow pairing stays open regardless.
    func cancelPairing() {
        link.pairingOpen = autoAllow
        syncLink()
    }

    /// Answers the request the alert was opened with. Anything else (the alert outlived it) is a
    /// click on nothing: it must never allow whichever phone is asking now.
    func resolvePairing(_ request: PairingRequest, allow: Bool) {
        guard model.pairingRequest?.id == request.id else { return }
        model.pairingRequest = nil
        request.respond(allow)
    }

    func remove(_ phone: PairedPhone) {
        link.remove(phone.id)
        syncLink()
    }

    private func pairing(_ event: PairingEvent) {
        switch event {
        case .request(let request):
            if autoAllow {
                NSLog("PHICE --auto-allow: accepted pairing request from %@", request.deviceName)
                return request.respond(true)
            }
            // The link asks about one phone at a time; a second never takes the alert from the first.
            guard model.pairingRequest == nil else { return request.respond(false) }
            model.pairingRequest = request
            model.pairingNote = nil
            onNeedsWindow?()
        case .withdrawn:
            guard model.pairingRequest != nil else { return }
            model.pairingRequest = nil
            model.pairingNote = "The iPhone stopped asking. Click Pair New iPhone to try again."
        case .conflict:
            model.pairingRequest = nil
            model.pairingNote = "Two devices asked to pair at the same time, so both were refused. "
                + "If only one was yours, someone nearby tried to pair. Try again."
            onNeedsWindow?()
        }
    }

    /// What the window shows of the link, taken whenever it says something changed.
    private func syncLink() {
        if autoAllow, !link.pairingOpen { link.pairingOpen = true }
        model.pairingOpen = link.pairingOpen
        if !link.pairingOpen { model.pairingDeadline = nil }
        model.pairedPhones = link.pairedPhones
    }

    /// Whether the grant changed since the last look. The phone is told, and the poster stops or
    /// starts posting with it.
    func refreshAccessibility() {
        let granted = accessibilityProbe()
        (poster as? QuartzPoster)?.trusted = granted
        guard granted != model.accessibilityGranted else { return }
        model.accessibilityGranted = granted
        send(.state(accessibility: granted))
    }

    /// Constraint 6: asked from here, so macOS lists Phice and not a terminal.
    func requestAccessibility() {
        CGRequestPostEventAccess()
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: pane)!)
    }

    func refreshLoginItem() {
        model.loginItemEnabled = LoginItem.status == .enabled
        model.loginItemNote = LoginItem.status == .requiresApproval
            ? "Switch Phice on in System Settings › General › Login Items." : nil
    }

    func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(on)
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            model.loginItemNote = error.localizedDescription
        }
    }

    /// A new Accessibility grant is applied by macOS only to a process started after it.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
