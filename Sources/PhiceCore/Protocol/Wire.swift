import Foundation

/// One clipboard entry as the phone shows it. The Mac keeps the full contents; the phone only previews.
public struct ClipItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text, link, image, file
    }

    public var id: String
    public var kind: Kind
    /// A text snippet, the URL, or the file name.
    public var preview: String
    /// A small PNG, for images only.
    public var thumbnail: Data?
    public var date: Date

    public init(id: String, kind: Kind, preview: String, thumbnail: Data? = nil, date: Date) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.thumbnail = thumbnail
        self.date = date
    }
}

public enum PhoneToMac: Codable, Sendable, Equatable {
    case hello(deviceName: String, appVersion: String)
    case events([PadEvent])
    /// The effective trackpad settings: the Mac's own, with the phone's overrides applied.
    case settings(TrackpadSettings)
    case enabled(Bool)
    case heartbeat
    /// Start or stop writing the session to a JSONL file on the Mac, for replay tests.
    case record(Bool)
    /// Raw touches, sent only while recording.
    case frames([TouchFrame])
}

public enum MacToPhone: Codable, Sendable, Equatable {
    case hello(macName: String, settings: TrackpadSettings)
    case state(accessibility: Bool)
    case clipboard([ClipItem])
    /// What the pill holds, or nil when it is empty.
    case pill(ClipItem?)
    case shortcuts([String])
    /// Whether the last drop changed the pasteboard; false plays the error haptic.
    case dropResult(ok: Bool)
}
