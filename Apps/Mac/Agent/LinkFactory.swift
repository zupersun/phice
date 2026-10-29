import PhiceNet

/// The one place that decides which transport the agent speaks. Loopback has no phone on the other
/// end; the real link replaces this body with `NetworkMacLink()`.
enum LinkFactory {
    @MainActor static func make() -> any MacLink { Loopback.pair().mac }
}
