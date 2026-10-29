import Foundation
import PhiceNet

/// Onboarding's order: install the agent, grant Accessibility, choose a Mac, click Allow on it,
/// turn the phone sideways. The link decides when Allow was clicked.
struct OnboardingFlow: Equatable {
    enum Step: Equatable {
        case install, accessibility, choose
        case allow(macName: String)
        case sideways
    }

    private(set) var step = Step.install

    mutating func next() {
        switch step {
        case .install: step = .accessibility
        case .accessibility: step = .choose
        default: break
        }
    }

    mutating func chose(_ mac: DiscoveredMac) {
        step = .allow(macName: mac.name)
    }

    /// Connected means the Mac allowed this phone; falling back to searching means it refused.
    mutating func linkChanged(to state: LinkState) {
        switch (step, state) {
        case (.choose, .connected), (.allow, .connected): step = .sideways
        case (.allow, .searching), (.allow, .idle): step = .choose
        default: break
        }
    }

    /// Once the phone is sideways onboarding is done for good.
    @MainActor static func finish(_ model: AppModel, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: "onboarded")
        model.showOnboarding = false
    }
}
