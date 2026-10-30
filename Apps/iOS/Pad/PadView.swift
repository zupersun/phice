import SwiftUI
import UIKit

/// The trackpad: black, edge to edge, everything but the pill and the open column. While it is up
/// the screen stays awake at the user's own brightness (a black OLED costs next to nothing, and
/// turning it down made the pill look as if it dimmed by itself), and edge swipes stay here.
struct PadView: View {
    let model: AppModel

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
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
