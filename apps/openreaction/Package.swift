// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh); source builds compile licensing and the updater out
// entirely. Every build links the shared licensing rules
// (packages/openapps-licensing: the badge type the UI carries); only a
// licensed build links its Dodo, trial registry and preferences clients,
// and only an official build the updater. Nothing is fetched: both are
// local packages in this repository.
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

// The shared licensing rules, records and badge (LICENSING.md).
var appDependencies: [Target.Dependency] = [
    "OpenReactionCore",
    .product(name: "OpenAppsLicensing", package: "openapps-licensing"),
]
var packageDependencies: [Package.Dependency] = [.package(path: "../../packages/openapps-licensing")]
if licensing {
    // Dodo Payments, the trial registry, the hardware UUID and the
    // preferences journal: only a build that talks to them links them.
    appDependencies.append(.product(name: "OpenAppsLicensingClients", package: "openapps-licensing"))
}
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
