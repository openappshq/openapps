// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh); source builds compile licensing and the updater out
// entirely, and fetch no dependencies.
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
var appLinkerSettings: [LinkerSetting] = []
if official {
    // Sparkle 2.10.0, pinned by commit: the binary framework's checksum is
    // part of that commit's manifest, so a moved tag cannot change it.
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", revision: "eef1a539a373c1f1a320624b1130fc5de7b2e100"))
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
    // scripts/bundle.sh embeds Sparkle.framework in Contents/Frameworks.
    appLinkerSettings.append(.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]))
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
            swiftSettings: appSettings,
            linkerSettings: appLinkerSettings
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
