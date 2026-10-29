import SwiftUI

/// The surface the pill grows into: itself, the hold menu, or the clipboard column. One shape whose
/// frame, corners and inks spring between the three, so the pill visibly becomes each of them.
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
        let isPill = surface == .pill
        shape.fill(isPill ? Color.black : Palette.panel)
            .overlay(shape.strokeBorder(isPill ? Color.white.opacity(border) : Palette.line,
                                        lineWidth: isPill ? PillGeometry.border : 1))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

/// The hold menu's three buttons, glyphs only. Touches are handled by `PillLayer`.
struct HoldMenuView: View {
    let geometry: PillGeometry
    let highlight: MenuItem?
    let enabled: Bool

    var body: some View {
        ForEach(MenuItem.allCases) { item in
            ZStack {
                Circle().fill(item == .power ? stateColour.opacity(0.2) : Color.clear)
                if item == highlight { Circle().fill(Color.white.opacity(0.16)) }
                Image(systemName: symbol(item))
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(item == .power ? stateColour
                                     : item == highlight ? .white : Palette.ink)
            }
            .frame(width: 48, height: 48)
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
