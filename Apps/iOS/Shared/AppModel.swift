import Foundation
import Observation
import PhiceCore
import PhiceNet

enum GlowColor: String, Codable, CaseIterable {
    case warmWhite, coolWhite, blue, green

    /// The one definition of each preset, so the glow and the settings swatch cannot drift apart.
    var hex: Int {
        switch self {
        case .warmWhite: 0xFFF6E6
        case .coolWhite: 0xEAF2FF
        case .blue: 0x0A84FF
        case .green: 0x30D158
        }
    }
}

/// The Appearance settings. Applies to the phone only; the Mac never sees it.
struct Appearance: Codable, Equatable {
    var glow = true
    var glowColor = GlowColor.warmWhite
    var glowIntensity = 1.0
    var borderBrightness = 1.0
}

/// State the pad and the pill share. The pad writes what the fingers are doing; the pill draws it;
/// the link fills in what the Mac says. Add behaviour in extensions in your own folder, not here.
@MainActor @Observable final class AppModel {
    let link: any PhoneLink

    // The Mac
    private(set) var linkState = LinkState.idle
    /// Macs the link can see, mirrored so views update when one appears or opens pairing.
    private(set) var macs: [DiscoveredMac] = []
    private(set) var macName: String?
    private(set) var accessibility = false
    /// The Mac's own trackpad settings, as it last reported them.
    private(set) var macSettings = TrackpadSettings()
    private(set) var shortcuts: [String] = []

    // Settings chosen on the phone
    /// The effective settings: the Mac's, with the phone's overrides. Sent to the Mac on change.
    var settings = TrackpadSettings() { didSet { if settings != oldValue { link.send(.settings(settings)) } } }
    var enabled = true { didSet { if enabled != oldValue { link.send(.enabled(enabled)) } } }
    var dropAction = DropAction.copy
    var appearance = Appearance()

    // What the recogniser sees, written by the pad
    var verdicts: [UInt16: TouchVerdict] = [:]
    var grab: Grab?
    /// Which edge the pill is on right now; follows the device-bottom edge through rotation.
    var pillSide = Side.left

    // What is on screen, written by the pill, onboarding and settings
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")
    var showSettings = false
    var menuOpen = false
    /// Width of the open clipboard column in points; the pad gives up that much on the pill's side.
    var columnWidth = 0.0
    /// While true the pad also streams raw touches, which the Mac writes to a JSONL recording.
    var recording = false { didSet { if recording != oldValue { link.send(.record(recording)) } } }

    // The clipboard, as the Mac reports it
    private(set) var pill: ClipItem?
    private(set) var clipboard: [ClipItem] = []
    /// Bumped on each drop result, so views can react to repeated outcomes.
    private(set) var dropResults = 0
    private(set) var lastDropOK = true

    init(link: any PhoneLink) {
        self.link = link
        link.onChange = { [weak self] in
            self?.linkState = link.state
            self?.macs = link.macs
        }
        link.onMessage = { [weak self] in self?.receive($0) }
    }

    func send(_ events: [PadEvent]) {
        guard enabled, !events.isEmpty else { return }
        link.send(.events(events))
    }

    private func receive(_ message: MacToPhone) {
        switch message {
        case let .hello(name, settings):
            macName = name
            // Follow the Mac's settings unless the phone has overridden them.
            if self.settings == macSettings { self.settings = settings }
            macSettings = settings
        case let .state(accessibility):
            self.accessibility = accessibility
        case let .clipboard(items):
            clipboard = items
        case let .pill(item):
            pill = item
        case let .shortcuts(names):
            shortcuts = names
        case let .dropResult(ok):
            lastDropOK = ok
            dropResults += 1
        case .heartbeat:
            break
        }
    }
}
