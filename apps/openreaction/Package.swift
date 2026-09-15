// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh); source builds compile licensing and the updater out
// entirely, and depend on nothing.
let environment = ProcessInfo.processInfo.environment
let licensing = environment["OPENAPPS_LICENSING"] == "1"
let official = environment["OPENAPPS_OFFICIAL"] == "1"
// Local update tests only (scripts/update-e2e.sh): the event tap stays off and
// test hooks are compiled in. Never set for a release; verify-release.sh checks.
let updateTesting = official && environment["OPENREACTION_UPDATE_TEST"] == "1"

var appSettings: [SwiftSetting] = []
if licensing { appSettings.append(.define("OPENAPPS_LICENSING")) }
if official { appSettings.append(.define("OPENAPPS_OFFICIAL")) }
if updateTesting { appSettings.append(.define("OPENREACTION_UPDATE_TESTING")) }

var appDependencies: [Target.Dependency] = ["OpenReactionCore"]
var packageDependencies: [Package.Dependency] = []
if official {
    // The shared in-app updater (RELEASES.md, "In-app updater").
    packageDependencies.append(.package(path: "../../packages/openapps-updater"))
    appDependencies.append(.product(name: "OpenAppsUpdater", package: "openapps-updater"))
}

let package = Package(
    name: "OpenReaction",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenReaction", targets: ["OpenReaction"]),
        .library(name: "OpenReactionCore", targets: ["OpenReactionCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // Pure, UI-free logic: trigger state machine, matching, placement math.
        .target(
            name: "OpenReactionCore",
            resources: [.copy("Resources/emoji.json")]
        ),
        // AppKit/SwiftUI shell: event tap, accessibility, panel, menu bar.
        .executableTarget(
            name: "OpenReaction",
            dependencies: appDependencies,
            resources: [.copy("Resources")],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "OpenReactionCoreTests",
            dependencies: ["OpenReactionCore"]
        ),
        // Drives the real tap callback with constructed, unposted CGEvents.
        .testTarget(
            name: "OpenReactionTests",
            dependencies: ["OpenReaction", "OpenReactionCore"],
            swiftSettings: appSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
