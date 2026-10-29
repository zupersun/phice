import Foundation
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

@Test func settingsFromAnOlderOrNewerAppDecodeWithDefaultsForWhatIsMissing() throws {
    // The phone (App Store) and the Mac agent (download) update separately, so a settings message
    // may lack a field the receiver knows about, or carry one it does not.
    let json = Data(#"{"tapToClick":false,"swipeSpaces":4,"someFutureSetting":1}"#.utf8)
    let settings = try JSONDecoder().decode(TrackpadSettings.self, from: json)
    #expect(settings.tapToClick == false)
    #expect(settings.swipeSpaces == .four)
    #expect(settings.scrollSpeed == TrackpadSettings().scrollSpeed)
    #expect(settings.missionControl == TrackpadSettings().missionControl)
}

@Test func settingsRoundTrip() throws {
    var settings = TrackpadSettings()
    settings.appExpose = .four
    settings.swipeSpaces = nil
    let back = try JSONDecoder().decode(TrackpadSettings.self, from: JSONEncoder().encode(settings))
    #expect(back == settings)
}

@Test func aSwitchedOffGestureStaysOffAcrossTheWire() throws {
    var settings = TrackpadSettings()
    settings.missionControl = nil
    let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    #expect(json.contains(#""missionControl":null"#))
    #expect(try JSONDecoder().decode(TrackpadSettings.self, from: Data(json.utf8)).missionControl == nil)
}
