import PhiceCore
import UIKit

/// Where the pad sits and which way it faces, in one place because the pill relies on it too.
///
/// The pad is the screen minus the open clipboard column, which sits on the pill's side. Pad
/// coordinates (touches, `Grab`) start at the pad's own top-left, so a pad point plus
/// `frame(...).origin` is a screen point.
enum PadLayout {
    static func frame(screen: CGSize, column: Double, side: Side) -> CGRect {
        let column = min(max(column, 0), screen.width)
        return CGRect(x: side == .left ? column : 0, y: 0,
                      width: screen.width - column, height: screen.height)
    }

    static func geometry(size: CGSize, side: Side) -> PadGeometry {
        PadGeometry(width: size.width, height: size.height, pillSide: side)
    }

    /// The pill sits on the device's bottom edge. UIKit names a landscape interface by where that
    /// edge went: `.landscapeLeft` has it on the left.
    static func pillSide(for orientation: UIInterfaceOrientation) -> Side? {
        switch orientation {
        case .landscapeLeft: .left
        case .landscapeRight: .right
        default: nil
        }
    }

    static func orientations(onboarding: Bool) -> UIInterfaceOrientationMask {
        onboarding ? .portrait : .landscape
    }
}

extension AppModel {
    /// The pad's frame on a screen of this size; see `PadLayout`.
    func padFrame(in screen: CGSize) -> CGRect {
        PadLayout.frame(screen: screen, column: columnWidth, side: pillSide)
    }
}
