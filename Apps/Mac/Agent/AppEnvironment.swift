import AppKit
import Foundation

enum AppEnvironment {
    /// The test host launches the real app; it must stay inert there (no window, no timers, no link).
    static let isTesting = [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
    ].contains { ProcessInfo.processInfo.environment[$0] != nil }

    /// Application Support/Phice: the history, the pill and recorded sessions.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Phice", isDirectory: true)
    }

    /// Started by macOS at login rather than by the user, so it should not put a window in their face.
    static func launchedAsLoginItem(_ launch: NSAppleEventDescriptor?) -> Bool {
        launch?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}
