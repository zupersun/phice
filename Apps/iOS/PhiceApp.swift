import SwiftUI

@main
struct PhiceApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
