import SwiftUI

/// The whole app: onboarding until a Mac is paired, then the pad with the pill on top.
/// Touches that begin on the pill land on `PillLayer`, which sits above the pad; every other
/// touch falls through to `PadView`.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.showOnboarding {
            OnboardingView(model: model)
        } else {
            ZStack {
                PadView(model: model)
                PillLayer(model: model)
            }
            .ignoresSafeArea()
            .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        }
    }
}
