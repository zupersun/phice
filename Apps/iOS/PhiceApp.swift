import PhiceNet
import SwiftUI

@main
struct PhiceApp: App {
    @State private var setup = AppSetup()

    var body: some Scene {
        WindowGroup {
            // `-probe` (devicectl launch argument) opens the contact-size probe instead.
            if CommandLine.arguments.contains("-probe") {
                ProbeView().ignoresSafeArea().statusBarHidden()
            } else {
                RootView(model: setup.model).statusBarHidden()
            }
        }
    }
}

@MainActor final class AppSetup {
    let model: AppModel
    private let devMac: DevMac

    init() {
        // shortcut: an in-memory Mac until PhiceNet's real link is merged in Phase 2.
        let (phone, mac) = Loopback.pair()
        devMac = DevMac(mac: mac)
        model = AppModel(link: phone)
        phone.start()
    }
}
