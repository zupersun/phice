import SwiftUI

/// The surface the pill grows into: itself, the hold menu, or the clipboard column. One shape whose
/// frame and corners spring between the three, so the pill visibly becomes each of them. The menu
/// wears the pill's own black and white border; only the column is a panel.
enum Surface {
    case pill, menu, column

    func rect(_ g: PillGeometry) -> CGRect {
        switch self {
        case .pill: g.pill
        case .menu: g.menu
        case .column: g.column
        }
    }

    func cornerRadius(_ g: PillGeometry) -> CGFloat {
        self == .column ? 26 : rect(g).width / 2
    }
}

struct MorphSurface: View {
    let surface: Surface
    let geometry: PillGeometry
    let border: Double

    var body: some View {
        let rect = surface.rect(geometry)
        let shape = RoundedRectangle(cornerRadius: surface.cornerRadius(geometry))
        let isPanel = surface == .column
        shape.fill(isPanel ? Palette.panel : Color.black)
            .overlay(shape.strokeBorder(isPanel ? Palette.line : Color.white.opacity(border),
                                        lineWidth: isPanel ? 1 : PillGeometry.border))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

/// The hold menu's three glyphs, inside the grown pill. The power glyph carries Phice's green or
/// red; the item under the finger gets a faint disc. Touches are handled by `PillLayer`.
struct HoldMenuView: View {
    let geometry: PillGeometry
    let highlight: MenuItem?
    let enabled: Bool

    var body: some View {
        ForEach(MenuItem.allCases) { item in
            ZStack {
                if item == highlight { Circle().fill(Color.white.opacity(0.16)) }
                Image(systemName: symbol(item))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(item == .power ? stateColour : Color.white.opacity(PillInk.glyph))
            }
            .frame(width: 29, height: 29)
            .position(geometry.centre(of: item))
        }
        .allowsHitTesting(false)
    }

    private var stateColour: Color { enabled ? Palette.on : Palette.off }

    private func symbol(_ item: MenuItem) -> String {
        switch item {
        case .power: "power"
        case .clipboard: "clipboard"
        case .settings: "gearshape"
        }
    }
}

/// A dense blue running around the pill's border while the Mac is not connected. Still under
/// Reduce Motion.
struct ConnectingSweep: View {
    let rect: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let period = 1.6
            let seconds = context.date.timeIntervalSinceReferenceDate
            let turn = reduceMotion ? 0.3 : seconds.truncatingRemainder(dividingBy: period) / period
            Capsule()
                .strokeBorder(AngularGradient(stops: Palette.sweepStops, center: .center,
                                              angle: .degrees(turn * 360)), lineWidth: 3)
        }
        .frame(width: rect.width + 2, height: rect.height + 2)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
}
