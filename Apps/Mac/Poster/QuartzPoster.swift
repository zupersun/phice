import AppKit
import CoreGraphics
import PhiceCore

/// Posts the Mac's input with CGEvent. Main thread only, like everything that touches the cursor.
/// Without post-event access every call does nothing, so a missing grant cannot half-work.
final class QuartzPoster: EventPoster {
    /// Set by the controller from the Accessibility grant. Closed until it says otherwise.
    var trusted = false {
        didSet { if trusted { scrollWatch.start() } }
    }
    /// The shortcuts the Shortcuts app listed; a name from the phone must be one of them.
    var allowedShortcuts: Set<String> = []
    let scrollWatch = ScrollWatch()
    /// Events handed to the window server, for tests.
    private(set) var posted = 0

    private let clipboard: Clipboard
    private var lastPosted: CGPoint?
    private var accumulator = ScrollAccumulator()
    private var displays: [CGRect] = []
    private var displaysRead = 0.0

    init(clipboard: Clipboard) {
        self.clipboard = clipboard
    }

    var cursor: (x: Double, y: Double) { (position.x, position.y) }

    // MARK: Pointer

    func move(dx: Double, dy: Double, dragging: MouseButton?) {
        guard trusted else { return }
        let from = position
        post(from: from, to: CGPoint(x: from.x + dx, y: from.y + dy), dragging: dragging)
    }

    func moveTo(x: Double, y: Double, dragging: MouseButton?) {
        guard trusted else { return }
        post(from: position, to: CGPoint(x: x, y: y), dragging: dragging)
    }

    func button(_ button: MouseButton, down: Bool, clicks: Int) {
        guard trusted else { return }
        let type: CGEventType = switch (button, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        }
        let which: CGMouseButton = button == .left ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: which) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        send(event)
    }

    /// The cursor's position. The system reads back whole points, so a slow drag of fractions would
    /// stall; the last position posted is kept while the system still agrees with it.
    private var position: CGPoint {
        let system = CGEvent(source: nil)?.location ?? .zero
        if let last = lastPosted, hypot(system.x - last.x, system.y - last.y) < 1 { return last }
        return system
    }

    private func post(from: CGPoint, to target: CGPoint, dragging: MouseButton?) {
        let point = DisplayGeometry.clamp(target, to: displayRects())
        let (type, button): (CGEventType, CGMouseButton) = switch dragging {
        case .left?: (.leftMouseDragged, .left)
        case .right?: (.rightMouseDragged, .right)
        case nil: (.mouseMoved, .left)
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - from.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - from.y).rounded()))
        lastPosted = point
        send(event)
    }

    private func displayRects() -> [CGRect] {
        let now = CFAbsoluteTimeGetCurrent()
        if displays.isEmpty || now - displaysRead > 2 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetActiveDisplayList(16, &ids, &count) == .success {
                displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
            }
            displaysRead = now
        }
        return displays
    }

    // MARK: Scroll

    /// `dx`/`dy` are CGEvent deltas in pixels (positive `dy` scrolls up). nil when the fraction
    /// rounds to nothing and the event marks no phase.
    func scrollEvent(dx: Double, dy: Double, phase: ScrollPhase?,
                     momentum: MomentumPhase?) -> CGEvent? {
        if phase == .began { accumulator.reset() }
        let whole = accumulator.take(dx: dx, dy: dy)
        let marksAPhase = (phase != nil && phase != .changed)
            || (momentum != nil && momentum != .continue)
        guard whole != (0, 0) || marksAPhase else { return nil }
        // The tag records what was meant, so the watch can tell a reverser from our own correction.
        return ScrollEvent.make(
            dx: scrollWatch.reversedX ? -whole.dx : whole.dx,
            dy: scrollWatch.reversedY ? -whole.dy : whole.dy,
            phase: phase, momentum: momentum, tag: ScrollEvent.tag(dx: whole.dx, dy: whole.dy))
    }

    func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?) {
        guard trusted else { return }
        if let event = scrollEvent(dx: dx, dy: dy, phase: phase, momentum: momentum) { send(event) }
    }

    // MARK: Keys

    func shortcut(_ shortcut: Shortcut) {
        guard trusted else { return }
        switch shortcut {
        case .notificationCenter:
            MenuBarClock.press()
        case .launchpad:
            // macOS 26 renamed Launchpad Apps. Opening it works whatever the F4 key is bound to.
            let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            if let path = apps.first(where: FileManager.default.fileExists) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else if let stroke = shortcut.keystroke {
                key(stroke)
            }
        default:
            if let stroke = shortcut.keystroke { key(stroke) }
        }
    }

    func forceClick() {
        guard trusted else { return }
        key(finderIsFrontmost ? .quickLook : .lookUp)
    }

    private var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private func key(_ stroke: KeyStroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.code,
                                      keyDown: down) else { continue }
            event.flags = stroke.flags
            send(event)
        }
    }

    private func send(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
        posted += 1
    }

    // MARK: Clipboard

    func perform(_ action: DropAction) -> Bool {
        guard trusted else { return false }
        switch action {
        case .copy:
            return copy(.copy) != nil
        case .cut:
            // Finder's ⌘X does not cut files; copy and let the user move them where they paste.
            return copy(finderIsFrontmost ? .copy : .cut) != nil
        case .shortcut(let name):
            // The name goes to a command line: it must be one the Shortcuts app itself listed.
            guard allowedShortcuts.contains(name), !name.hasPrefix("-"), let item = copy(.copy) else {
                return false
            }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("phice-input")
            let items = clipboard.store.types(for: item.id) ?? []
            if let input = ShortcutInput.file(for: items, in: scratch) {
                ShortcutsCLI.run(name, input: input.url, temporary: input.temporary)
            }
            return true
        }
    }

    func paste(itemID: String) {
        guard trusted, clipboard.write(itemID: itemID) else { return }
        key(.paste)
        clipboard.pastedOut(itemID)
    }

    /// Press the keys, then wait for the pasteboard to answer. An app that copies lazily or not at
    /// all (an unselected web image) leaves the count where it was, and the phone plays its error.
    /// Blocks the main thread for at most 300 ms.
    private func copy(_ stroke: KeyStroke) -> ClipItem? {
        let before = clipboard.changeCount
        key(stroke)
        let deadline = CFAbsoluteTimeGetCurrent() + 0.3
        while clipboard.changeCount == before {
            guard CFAbsoluteTimeGetCurrent() < deadline else { return nil }
            usleep(10_000)
        }
        return clipboard.capture(asPill: true)
    }
}
