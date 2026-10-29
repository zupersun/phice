import CoreGraphics

/// Constraint 2: Scroll Reverser and its kind negate every scroll event they take for a mouse's,
/// posted ones included, and nothing short of looking tells. A tap behind every reverser reads our
/// tagged events as they come out; the poster pre-flips the next ones while the sign is flipped.
final class ScrollWatch {
    enum Mode { case listen, filter, off }

    private(set) var reversedX = false
    private(set) var reversedY = false
    private(set) var mode = Mode.off
    private var tap: CFMachPort?

    /// Compare an event's signs with the signs recorded in its tag.
    func observe(_ event: CGEvent) {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        guard ScrollEvent.isOurs(tag) else { return }
        let y = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let x = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        if tag & 1 != 0, y != 0 { reversedY = (y > 0) != (tag & 2 != 0) }
        if tag & 4 != 0, x != 0 { reversedX = (x > 0) != (tag & 8 != 0) }
    }

    /// Needs the Accessibility grant, so the controller calls it again when that arrives.
    @discardableResult
    func start() -> Mode {
        guard tap == nil else { return mode }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Listen-only first; some macOS versions want Input Monitoring for it, where a filter that
        // passes everything through needs only the Accessibility we have anyway.
        for (option, mode) in [(CGEventTapOptions.listenOnly, Mode.listen), (.defaultTap, .filter)] {
            guard let tap = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: option,
                eventsOfInterest: mask, callback: scrollTapCallback, userInfo: refcon)
            else { continue }
            self.tap = tap
            self.mode = mode
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return mode
        }
        return .off
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a slow tap off.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            observe(event)
        default:
            break
        }
    }
}

// The tap runs on the main run loop, the same thread that owns the watch.
private func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<ScrollWatch>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
