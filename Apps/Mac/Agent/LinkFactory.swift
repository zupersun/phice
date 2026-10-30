import Foundation
import PhiceNet

/// The one place that decides which transport the agent speaks.
enum LinkFactory {
    @MainActor static func make(autoAllow: Bool = false) -> any MacLink {
        let name = Host.current().localizedName ?? "Mac"
        #if DEBUG
        // Test runs keep no keys: a rebuilt ad-hoc binary would otherwise hit a Keychain prompt.
        if autoAllow { return NetworkMacLink(macName: name, keyStore: InMemoryKeyStore()) }
        #endif
        return NetworkMacLink(macName: name)
    }
}
