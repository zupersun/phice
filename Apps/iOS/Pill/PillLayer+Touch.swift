import PhiceCore
import SwiftUI

/// The pill's touches: hold for the menu, drag what it holds out onto the pad; taps on the open
/// menu; drags out of the column. None of these reach the pad.
extension PillLayer {
    func pillTouches(_ g: PillGeometry) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: g.pill.width + 16, height: g.pill.height + 16)
            .position(x: g.pill.midX, y: g.pill.midY)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { pillMoved($0, g) }
                .onEnded { pillLifted($0, g) })
            .accessibilityElement()
            .accessibilityLabel(model.pill.map { "Pill, holding \($0.preview)" } ?? "Pill, empty")
            .accessibilityHint("Hold for the menu")
            .accessibilityAction(named: model.enabled ? "Turn Phice off" : "Turn Phice on") {
                model.enabled.toggle()
            }
            .accessibilityAction(named: "Clipboard") { show(.column, g) }
            .accessibilityAction(named: "Settings") { model.showSettings = true }
    }

    /// While the menu is open every touch belongs to it: on an item it presses, elsewhere it closes.
    func menuTouches(_ g: PillGeometry) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let item = g.item(at: value.location)
                    guard menu.phase == .open else { return menu.move(to: value.location, over: item) }
                    menu.touchDown(over: item)
                    if !menu.isOpen { collapse() }
                }
                .onEnded { _ in perform(menu.lift(), g) })
    }

    /// Hold the column to fold it back into the pill; drag a row out to paste it where the cursor is.
    func columnTouches(_ g: PillGeometry) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: g.column.width, height: g.column.height)
            .position(x: g.column.midX, y: g.column.midY)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    guard press?.start == value.startLocation else {
                        return beginPress(at: value.startLocation) {
                            holds += 1
                            endPress()
                            collapse()
                        }
                    }
                    let items = model.clipboard
                    if press?.move(to: value.location, t: Self.now) == .drag,
                       let row = g.row(at: value.startLocation), row < items.count {
                        let item = items[row]
                        carried = Carried(item: item, out: DragOut(itemID: item.id, at: value.location),
                                          at: value.location)
                    }
                    dragMoved(to: value.location, g)
                }
                .onEnded { value in
                    endPress()
                    dragLifted(at: value.location, g)
                })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Clipboard")
            .accessibilityAction(named: "Close") { collapse() }
    }

    private func pillMoved(_ value: DragGesture.Value, _ g: PillGeometry) {
        guard press?.start == value.startLocation else {
            pressing = true
            return beginPress(at: value.startLocation) {
                pressing = false
                holds += 1
                menu.open(at: value.startLocation)
                show(.menu, g)
            }
        }
        if menu.phase == .held {
            return menu.move(to: value.location, over: g.item(at: value.location))
        }
        if press?.move(to: value.location, t: Self.now) == .drag {
            pressing = false
            if let item = model.pill {
                carried = Carried(item: item, out: DragOut(itemID: item.id, at: value.location),
                                  at: value.location)
            }
        }
        dragMoved(to: value.location, g)
    }

    private func pillLifted(_ value: DragGesture.Value, _ g: PillGeometry) {
        endPress()
        if menu.phase == .held { return perform(menu.lift(), g) }
        dragLifted(at: value.location, g)
    }

    /// A finger landed: unless it moves first, `onHold` runs after the hold delay.
    private func beginPress(at point: CGPoint, onHold: @escaping @MainActor () -> Void) {
        holdTask?.cancel()
        press = Press(at: point, t: Self.now)
        holdTask = Task {
            try? await Task.sleep(for: .seconds(Press.holdDelay), clock: .suspending)
            guard !Task.isCancelled, press?.tick(Self.now) == .hold else { return }
            onHold()
        }
    }

    private func endPress() {
        holdTask?.cancel()
        holdTask = nil
        press = nil
        pressing = false
    }

    private func dragMoved(to point: CGPoint, _ g: PillGeometry) {
        guard var carried else { return }
        let over = g.overPad(point, columnWidth: model.columnWidth)
        if let move = carried.out.move(to: point, overPad: over, t: Self.now) {
            model.send([move])
        }
        carried.at = point
        self.carried = carried
    }

    private func dragLifted(at point: CGPoint, _ g: PillGeometry) {
        guard let carried else { return }
        self.carried = nil
        if let paste = carried.out.lift(overPad: g.overPad(point, columnWidth: model.columnWidth)) {
            model.send([paste])
        }
    }

    private func perform(_ item: MenuItem?, _ g: PillGeometry) {
        switch item {
        case .power: model.enabled.toggle()
        case .clipboard: show(.column, g)
        case .settings:
            collapse()
            model.showSettings = true
        case nil: break
        }
    }

    func show(_ next: Surface, _ g: PillGeometry) {
        if next != .menu { menu.close() }
        surfaceShown = true
        withAnimation(motion) {
            surface = next
            model.columnWidth = next == .column ? g.columnWidth : 0
        }
    }

    /// Folds the menu or the column back into the pill, then hands drawing back to the pill itself.
    func collapse() {
        menu.close()
        guard surface != .pill else { return }
        withAnimation(motion) {
            surface = .pill
            model.columnWidth = 0
        } completion: {
            if surface == .pill { surfaceShown = false }
        }
    }
}
