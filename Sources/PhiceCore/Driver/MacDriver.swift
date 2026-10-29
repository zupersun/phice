/// Turns the phone's messages into posted input: Apple's curves, local momentum, the copy-drop and
/// paste sequences, and the silence timeout that releases a held button. Pure: time is passed in.
public final class MacDriver {
    /// After this long without any message (heartbeats included) a held button is released and
    /// momentum stops, so a phone that vanishes mid-drag never leaves the mouse button down.
    public static let silenceTimeout = 0.5

    private let poster: EventPoster

    public init(poster: EventPoster, settings: TrackpadSettings,
                curves: [AccelCurve], scrollCurves: [AccelCurve]) {
        self.poster = poster
    }

    /// Stub until the pointer work lands. Returns any replies for the phone (e.g. `dropResult`).
    public func handle(_ message: PhoneToMac, now: Double) -> [MacToPhone] { [] }

    /// Momentum steps and the silence timeout.
    public func tick(now: Double) {}
}
