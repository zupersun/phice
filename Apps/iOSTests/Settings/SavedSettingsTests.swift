import Foundation
import PhiceCore
import PhiceNet
import Testing
@testable import PhiceiOS

@MainActor private func freshDefaults() -> UserDefaults {
    let name = "phice.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor @Test func appearanceDropActionAndOverridesSurviveARelaunch() {
    let defaults = freshDefaults()
    let before = AppModel(link: Loopback.pair().phone)
    before.appearance.glow = false
    before.appearance.glowColor = .blue
    before.appearance.borderBrightness = 0.5
    before.dropAction = .shortcut(name: "Resize Image")
    before.saveLook(to: defaults)
    before.override({ $0.tapToClick = false }, in: defaults)

    let after = AppModel(link: Loopback.pair().phone)
    after.restoreSaved(from: defaults)
    #expect(after.appearance == before.appearance)
    #expect(after.dropAction == .shortcut(name: "Resize Image"))
    #expect(after.settings.tapToClick == false)
    #expect(after.isOverridingMac)
}

@MainActor @Test func nothingSavedLeavesTheDefaultsAndFollowsTheMac() {
    let model = AppModel(link: Loopback.pair().phone)
    model.restoreSaved(from: freshDefaults())
    #expect(model.appearance == Appearance())
    #expect(model.dropAction == .copy)
    #expect(!model.isOverridingMac)
}

@MainActor @Test func resettingToTheMacForgetsTheOverrides() {
    let defaults = freshDefaults()
    let model = AppModel(link: Loopback.pair().phone)
    model.override({ $0.trackingSpeed = 3 }, in: defaults)
    model.resetToMac(in: defaults)
    #expect(!model.isOverridingMac)

    let relaunched = AppModel(link: Loopback.pair().phone)
    relaunched.restoreSaved(from: defaults)
    #expect(relaunched.settings == TrackpadSettings())
}
