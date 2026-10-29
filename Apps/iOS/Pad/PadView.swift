import SwiftUI
import UIKit

/// The trackpad: black, edge to edge, everything but the pill and the open column. While it is up
/// and the app is active the screen stays awake at minimum brightness, and edge swipes stay here.
struct PadView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var shown = false
    @State private var dimmer = Dimmer()

    var body: some View {
        GeometryReader { geo in
            let frame = model.padFrame(in: geo.size)
            PadSurface(model: model)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
        .ignoresSafeArea()
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            shown = true
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            shown = false
            UIApplication.shared.isIdleTimerDisabled = false
            dimmer.dim(false)
        }
        .onChange(of: dim) { dimmer.dim(dim) }
    }

    /// Settings over the pad get the user's own brightness back, so they can be read.
    private var dim: Bool { shown && phase == .active && !model.showSettings }
}

/// Holds the user's brightness while the pad turns the screen down, to give it back.
@MainActor final class Dimmer {
    private var saved: CGFloat?

    func dim(_ on: Bool) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let screen = scene?.screen else { return }
        if on, saved == nil {
            saved = screen.brightness
            screen.brightness = 0
        } else if !on, let saved {
            screen.brightness = saved
            self.saved = nil
        }
    }
}
