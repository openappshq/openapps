// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 (see scripts/bundle.sh); source
// builds compile licensing out entirely.
let licensing = ProcessInfo.processInfo.environment["OPENAPPS_LICENSING"] == "1"

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
            resources: [.copy("Resources")],
            swiftSettings: licensing ? [.define("OPENAPPS_LICENSING")] : []
        ),
        .testTarget(
            name: "OpenReactionCoreTests",
            dependencies: ["OpenReactionCore"]
        ),
        // Drives the real tap callback with constructed, unposted CGEvents.
        .testTarget(
            name: "OpenReactionTests",
            dependencies: ["OpenReaction", "OpenReactionCore"],
            swiftSettings: licensing ? [.define("OPENAPPS_LICENSING")] : []
        ),
    ],
    swiftLanguageModes: [.v6]
)
