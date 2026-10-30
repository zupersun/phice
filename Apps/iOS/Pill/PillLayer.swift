import PhiceCore
import PhiceNet
import SwiftUI

/// The pill and everything that grows out of it: the hold menu, the clipboard column, the copy
/// gesture's bead and the swallow. It sits above the pad and only the pill, the open menu and the
/// open column hit-test, so every other touch falls through to the pad.
struct PillLayer: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var menu = HoldMenu()
    /// What the pill has grown into, and whether that shape is drawn instead of the pill itself.
    @State var surface = Surface.pill
    @State var surfaceShown = false
    @State var press: Press?
    @State var pressing = false
    @State var holdTask: Task<Void, Never>?
    @State var carried: Carried?
    @State var swallow = Swallow()
    @State var settling = false
    /// Filled from the merge until the Mac says otherwise: the drop failed, or the pill changed.
    @State var optimistic = false
    @State var resultsAtRelease = 0
    // Haptic triggers.
    @State var holds = 0
    @State var merges = 0
    @State var errors = 0

    static let space = "pill"

    /// An item being dragged out of the pill or the column toward the pad.
    struct Carried {
        var item: ClipItem
        var out: DragOut
        var at: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            let g = PillGeometry(screen: proxy.size, side: model.pillSide)
            ZStack(alignment: .topLeading) {
                canvas(g)
                if !model.linkState.isConnected, !surfaceShown { ConnectingSweep(rect: g.pill) }

                if surfaceShown { MorphSurface(surface: surface, geometry: g, border: border) }
                if surface == .menu {
                    HoldMenuView(geometry: g, highlight: menu.highlight, enabled: model.enabled)
                        .transition(appearing)
                }
                if surface == .column {
                    ClipboardColumn(geometry: g, items: model.clipboard, carried: carried?.item.id) {
                        model.send([.paste(itemID: $0.id)])
                    }
                        .transition(.opacity)
                    columnTouches(g)
                }
                if menu.phase == .open || menu.phase == .pressing { menuTouches(g) }
                if surface == .pill || press != nil { pillTouches(g) }
                if let carried {
                    ClipRow(item: carried.item, lifted: true)
                        .frame(width: 187, height: PillGeometry.rowHeight)
                        .position(x: carried.at.x, y: carried.at.y - 36)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
            .onChange(of: model.grab) { grabChanged(from: $0, to: $1, g) }
            .onChange(of: menu.isOpen) { model.menuOpen = $1 }
        }
        .onChange(of: model.dropResults) {
            guard !model.lastDropOK else { return }
            optimistic = false
            errors += 1
        }
        .onChange(of: model.pill) { optimistic = false }
        .onAppear { model.restoreSaved() }
        .sensoryFeedback(.selection, trigger: menu.highlight) { $1 != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: holds)
        .sensoryFeedback(.success, trigger: merges)
        .sensoryFeedback(.error, trigger: errors)
    }

    private func canvas(_ g: PillGeometry) -> some View {
        TimelineView(.animation(paused: model.grab == nil && !settling)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let grab = model.grab.map { g.onScreen($0, columnWidth: model.columnWidth) }
            let distance = grab.map { Double(g.distanceFromEdge($0)) }
            let frame = swallow.frame(at: t, live: grab, distance: distance,
                                      pill: CGPoint(x: g.pill.midX, y: g.pill.midY),
                                      reduceMotion: reduceMotion)
            PillCanvas(press: pressing ? 1 : 0, geometry: g, frame: frame, border: border,
                       filled: optimistic || model.pill != nil, drawsPill: !surfaceShown)
                .animation(.easeOut(duration: 0.3), value: pressing)
        }
    }

    var border: Double {
        PillInk.border(model.appearance.borderBrightness, connected: model.linkState.isConnected)
    }

    var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.25)
    }

    private var appearing: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6))
    }

    /// The copy gesture: the bead appears with the grab and either swallows or shrinks when it ends.
    private func grabChanged(from old: Grab?, to new: Grab?, _ g: PillGeometry) {
        let t = Self.now
        if old == nil, new != nil {
            swallow.begin(at: t)
            settling = true
            carried = nil
            collapse()
        }
        guard let old, new == nil else { return }
        let bead = g.onScreen(old, columnWidth: model.columnWidth)
        swallow.end(at: t, bead: bead, distance: g.distanceFromEdge(bead), swallowed: old.inZone)
        if old.inZone {
            resultsAtRelease = model.dropResults
            Task {
                try? await Task.sleep(for: .seconds(Swallow.pullIn))
                merged()
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if model.grab == nil, swallow.isSettled(at: Self.now) { settling = false }
        }
    }

    /// The bead has joined the pill. A drop the Mac already reported as failed stays outline.
    private func merged() {
        guard model.dropResults == resultsAtRelease || model.lastDropOK else { return }
        optimistic = true
        merges += 1
    }

    static var now: Double { Date.now.timeIntervalSinceReferenceDate }
}

extension LinkState {
    var isConnected: Bool { self == .connected }
}
