import PhiceCore
import UIKit

/// The haptics the pad plays: a Force Touch trackpad's clicks, and the drop zone's tick. Drop
/// success and error are the pill's.
enum Haptic: Equatable {
    /// A finger pressed: the button went down.
    case press
    /// The press let go, whether the finger lifted or eased off: the button came up.
    case release
    /// The held item crossed into the drop zone.
    case zone

    /// What to play for one recogniser step, from what it said before to what it says now.
    static func cues(verdicts old: [UInt16: TouchVerdict], _ new: [UInt16: TouchVerdict],
                     grab oldGrab: Grab?, _ newGrab: Grab?) -> [Haptic] {
        var cues: [Haptic] = []
        if new.contains(where: { $0.value == .pressed && old[$0.key] != .pressed }) {
            cues.append(.press)
        }
        if old.contains(where: { $0.value == .pressed && new[$0.key] != .pressed }) {
            cues.append(.release)
        }
        if newGrab?.inZone == true, oldGrab?.inZone != true { cues.append(.zone) }
        return cues
    }
}

@MainActor final class HapticPlayer {
    private let click: UIImpactFeedbackGenerator
    private let tick: UIImpactFeedbackGenerator

    init(view: UIView) {
        click = UIImpactFeedbackGenerator(style: .rigid, view: view)
        tick = UIImpactFeedbackGenerator(style: .light, view: view)
    }

    /// Keeps the Taptic Engine awake, which lasts only seconds, so a click plays the instant it is
    /// due. Called as a finger lands and every second while one stays down.
    func prepare() {
        click.prepare()
        tick.prepare()
    }

    func play(_ haptic: Haptic) {
        switch haptic {
        case .press: click.impactOccurred(intensity: 0.85)
        case .release: click.impactOccurred(intensity: 0.45)
        case .zone: tick.impactOccurred(intensity: 0.7)
        }
    }
}
