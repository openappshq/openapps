// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenReaction",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenReaction", targets: ["OpenReaction"]),
        .library(name: "OpenReactionCore", targets: ["OpenReactionCore"]),
    ],
    targets: [
        // Pure, UI-free logic: trigger state machine, matching, placement math.
        .target(
            name: "OpenReactionCore",
            resources: [.copy("Resources/emoji.json")]
        ),
        // AppKit/SwiftUI shell: event tap, accessibility, panel, menu bar.
        .executableTarget(
            name: "OpenReaction",
            dependencies: ["OpenReactionCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "OpenReactionCoreTests",
            dependencies: ["OpenReactionCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
