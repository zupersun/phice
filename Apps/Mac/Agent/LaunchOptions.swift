import Foundation

/// The launch arguments the agent understands, for end-to-end tests with no phone, cursor or user.
struct LaunchOptions: Equatable {
    /// Post to a `FakePoster` instead of the real cursor.
    var fakePoster = false
    /// `--fake-poster PATH`: also append every poster call to PATH, one JSON line each.
    var fakePosterLog: URL?
    /// Accept every pairing request. Honoured by `AgentController` in DEBUG builds only.
    var autoAllow = false

    init(arguments: [String]) {
        if let flag = arguments.firstIndex(of: "--fake-poster") {
            fakePoster = true
            if let path = arguments.dropFirst(flag + 1).first, !path.hasPrefix("--") {
                fakePosterLog = URL(fileURLWithPath: path)
            }
        }
        autoAllow = arguments.contains("--auto-allow")
    }
}
