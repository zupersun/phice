import PhiceCore
import PhiceNet
import Testing
@testable import PhiceiOS

@MainActor @Test func followsTheMacsSettingsUntilThePhoneOverridesThem() async {
    let (phone, mac) = Loopback.pair()
    let model = AppModel(link: phone)
    mac.onPairingRequest = { $0.respond(true) }
    phone.start()
    phone.pair(with: phone.macs[0])

    var macSettings = TrackpadSettings()
    macSettings.trackingSpeed = 2.5
    mac.send(.hello(macName: "Mac", settings: macSettings))
    for _ in 0 ..< 10 where model.macName == nil { await Task.yield() }
    #expect(model.settings.trackingSpeed == 2.5)

    model.settings.tapToClick = false
    var changed = macSettings
    changed.trackingSpeed = 1.5
    mac.send(.hello(macName: "Mac", settings: changed))
    for _ in 0 ..< 10 where model.macSettings.trackingSpeed != 1.5 { await Task.yield() }
    #expect(model.settings.trackingSpeed == 2.5)
    #expect(model.settings.tapToClick == false)
}
