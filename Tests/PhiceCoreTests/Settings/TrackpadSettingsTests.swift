import Testing
@testable import PhiceCore

@Test func defaultsAreWhatMacOSAppliesWhenTheSlidersWereNeverMoved() {
    // Measured on a Mac with no com.apple.trackpad.scaling: HIDTrackpadAcceleration = 45056 and
    // HIDTrackpadScrollAcceleration = 20480, both 16.16 fixed point.
    let defaults = TrackpadSettings()
    #expect(defaults.trackingSpeed == 45056.0 / 65536)
    #expect(defaults.scrollSpeed == 20480.0 / 65536)
}

@Test func driverScrollsFasterAtAHigherScrollSpeed() {
    func scrolled(at speed: Double) -> Double {
        let poster = FakePoster()
        var settings = TrackpadSettings()
        settings.scrollSpeed = speed
        let driver = MacDriver(poster: poster, settings: settings,
                               curves: ThisMac.pointer, scrollCurves: ThisMac.scroll)
        _ = driver.handle(.events([
            .scroll(dx: 0, dy: 0, phase: .began, t: 0),
            .scroll(dx: 0, dy: 40, phase: .changed, t: 1.0 / 60),
        ]), now: 0)
        return poster.calls.reduce(0) {
            if case let .scroll(_, dy, _, _) = $1 { return $0 + abs(dy) } else { return $0 }
        }
    }
    #expect(scrolled(at: 3) > scrolled(at: 0.3125))
}
