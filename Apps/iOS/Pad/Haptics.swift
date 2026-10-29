import PhiceCore
import UIKit

/// The two haptics the pad plays. Drop success and error are the pill's.
enum Haptic: Equatable {
    /// A finger turned into a force press.
    case detent
    /// The held item crossed into the drop zone.
    case zone

    /// What to play for one recogniser step, from what it said before to what it says now.
    static func cues(verdicts old: [UInt16: TouchVerdict], _ new: [UInt16: TouchVerdict],
                     grab oldGrab: Grab?, _ newGrab: Grab?) -> [Haptic] {
        var cues: [Haptic] = []
        if new.contains(where: { $0.value == .force && old[$0.key] != .force }) {
            cues.append(.detent)
        }
        if newGrab?.inZone == true, oldGrab?.inZone != true { cues.append(.zone) }
        return cues
    }
}

@MainActor final class HapticPlayer {
    private let detent: UIImpactFeedbackGenerator
    private let tick: UIImpactFeedbackGenerator

    init(view: UIView) {
        detent = UIImpactFeedbackGenerator(style: .rigid, view: view)
        tick = UIImpactFeedbackGenerator(style: .light, view: view)
    }

    /// Called as a finger lands, so the Taptic Engine is awake by the time a cue plays.
    func prepare() {
        detent.prepare()
        tick.prepare()
    }

    func play(_ haptic: Haptic) {
        switch haptic {
        case .detent: detent.impactOccurred(intensity: 1)
        case .zone: tick.impactOccurred(intensity: 0.7)
        }
    }
}
