import Foundation
import PhiceCore

/// What the phone remembers between launches: the trackpad overrides, the appearance and what a
/// drop into the pill does. Overrides are stored only once the user changes a trackpad setting
/// here, so until then the phone keeps following the Mac's own settings.
@MainActor extension AppModel {
    private enum Key {
        static let overrides = "settings.overrides"
        static let appearance = "settings.appearance"
        static let dropAction = "settings.dropAction"
    }

    /// Loads what was saved. Called once the pad first appears.
    func restoreSaved(from defaults: UserDefaults = .standard) {
        if let saved: Appearance = defaults.decoded(Key.appearance) { appearance = saved }
        if let saved: DropAction = defaults.decoded(Key.dropAction) { dropAction = saved }
        if let saved: TrackpadSettings = defaults.decoded(Key.overrides) { settings = saved }
    }

    func saveLook(to defaults: UserDefaults = .standard) {
        defaults.encode(appearance, Key.appearance)
        defaults.encode(dropAction, Key.dropAction)
    }

    /// The user changed a trackpad setting on the phone: it now overrides the Mac's.
    func override(_ change: (inout TrackpadSettings) -> Void, in defaults: UserDefaults = .standard) {
        change(&settings)
        defaults.encode(settings, Key.overrides)
    }

    var isOverridingMac: Bool { settings != macSettings }

    /// Back to the Mac's own trackpad settings.
    func resetToMac(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.overrides)
        settings = macSettings
    }
}

private extension UserDefaults {
    func decoded<T: Decodable>(_ key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func encode<T: Encodable>(_ value: T, _ key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}
