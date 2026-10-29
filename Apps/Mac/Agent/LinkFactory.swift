import Foundation
import PhiceNet

/// The one place that decides which transport the agent speaks.
enum LinkFactory {
    @MainActor static func make() -> any MacLink {
        NetworkMacLink(macName: Host.current().localizedName ?? "Mac")
    }
}
