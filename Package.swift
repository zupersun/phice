// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhiceKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PhiceCore", targets: ["PhiceCore"]),
        .library(name: "PhiceNet", targets: ["PhiceNet"]),
    ],
    targets: [
        // Pure: Foundation only, no I/O, no UIKit/AppKit. Everything that decides behaviour lives here.
        .target(name: "PhiceCore"),
        // Network.framework: discovery, pairing, the encrypted link.
        .target(name: "PhiceNet", dependencies: ["PhiceCore"]),
        .executableTarget(name: "phice-replay", dependencies: ["PhiceCore"], path: "tools/phice-replay"),
        .executableTarget(name: "fake-phone", dependencies: ["PhiceCore", "PhiceNet"], path: "tools/fake-phone"),
        .executableTarget(name: "trackpad-probe", path: "tools/trackpad-probe"),
        .testTarget(name: "PhiceCoreTests", dependencies: ["PhiceCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PhiceNetTests", dependencies: ["PhiceNet"]),
    ]
)
