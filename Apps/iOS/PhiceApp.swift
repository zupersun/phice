import PhiceNet
import SwiftUI
import UIKit

@main
struct PhiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            // `-probe` (devicectl launch argument) opens the contact-size probe instead.
            if AppDelegate.probe {
                ProbeView().ignoresSafeArea().statusBarHidden()
            } else {
                Oriented(model: AppDelegate.setup.model)
            }
        }
    }
}

/// Answers which ways the window may face. The app's objects are static: SwiftUI puts its own
/// object in `UIApplication.shared.delegate`, so this one cannot be found through it.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    static let probe = CommandLine.arguments.contains("-probe")
    static let setup = AppSetup()

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        if Self.probe { return .allButUpsideDown }
        return PadLayout.orientations(onboarding: Self.setup.model.showOnboarding)
    }
}

/// Onboarding stands up and the pad lies down: turns the window when one gives way to the other.
private struct Oriented: View {
    let model: AppModel

    var body: some View {
        RootView(model: model)
            .statusBarHidden()
            .onChange(of: model.showOnboarding) {
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                guard let scene else { return }
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                let mask = PadLayout.orientations(onboarding: model.showOnboarding)
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
    }
}

@MainActor final class AppSetup {
    let model: AppModel
    /// The in-memory Mac behind `-devmac`, for working on the UI with no Mac at hand.
    private var devMac: DevMac?

    init() {
        if CommandLine.arguments.contains("-devmac") {
            let (phone, mac) = Loopback.pair()
            devMac = DevMac(mac: mac)
            model = AppModel(link: phone)
        } else {
            model = AppModel(link: NetworkPhoneLink(deviceName: UIDevice.current.name))
        }
        model.link.start()
    }
}
