import Foundation
import PhiceCore
import PhiceNet
import Testing
@testable import PhiceiOS

@MainActor private func settle(_ until: () -> Bool) async {
    for _ in 0 ..< 20 where !until() { await Task.yield() }
}

@MainActor @Test func onboardingRunsFromInstallToSidewaysAgainstAMacThatAllows() async {
    let (phone, mac) = Loopback.pair()
    mac.pairingOpen = true
    mac.onPairingRequest = { $0.respond(true) }
    let model = AppModel(link: phone)
    phone.start()

    var flow = OnboardingFlow()
    #expect(flow.step == .install)
    flow.next()
    #expect(flow.step == .accessibility)
    flow.next()
    #expect(flow.step == .choose)

    let choice = model.link.macs.first { $0.pairingOpen }!
    flow.chose(choice)
    #expect(flow.step == .allow(macName: "Loopback Mac"))
    model.link.pair(with: choice)
    await settle { model.linkState == .connected }
    flow.linkChanged(to: model.linkState)
    #expect(flow.step == .sideways)

    let defaults = UserDefaults(suiteName: "phice.tests.\(UUID().uuidString)")!
    model.showOnboarding = true
    OnboardingFlow.finish(model, defaults: defaults)
    #expect(defaults.bool(forKey: "onboarded"))
    #expect(!model.showOnboarding)
}

@MainActor @Test func aMacThatRefusesSendsOnboardingBackToTheList() async {
    let (phone, mac) = Loopback.pair()
    mac.pairingOpen = true
    mac.onPairingRequest = { $0.respond(false) }
    let model = AppModel(link: phone)
    phone.start()

    var flow = OnboardingFlow()
    flow.next()
    flow.next()
    flow.chose(model.link.macs[0])
    model.link.pair(with: model.link.macs[0])
    await settle { model.linkState == .searching }
    flow.linkChanged(to: model.linkState)
    #expect(flow.step == .choose)
}

@Test func connectingWhileStillOnTheEarlySetupStepsDoesNotSkipThem() {
    var flow = OnboardingFlow()
    flow.linkChanged(to: .connected)
    #expect(flow.step == .install)
}
