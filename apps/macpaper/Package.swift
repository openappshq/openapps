// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh); source builds compile licensing and the updater out
// entirely. Every build links the shared licensing rules
// (packages/openapps-licensing: the badge type the UI carries and the
// manager the tests drive with fakes); only a licensed build links its Dodo,
// trial registry and preferences clients, and only an official build the
// updater. Nothing is fetched: both are local packages in this repository.
let environment = ProcessInfo.processInfo.environment
let licensing = environment["OPENAPPS_LICENSING"] == "1"
let official = environment["OPENAPPS_OFFICIAL"] == "1"
// Local update tests only (scripts/update-e2e.sh): the login-item default
// and the setup guide stay off and test hooks are compiled in. Never set
// for a release; verify-release.sh checks. Never with licensing: the test
// variant must not link the record store, the registry or Dodo's client,
// and its licensing-off launch path is the one that knows to skip the
// login item.
let updateTesting = official && environment["MACPAPER_UPDATE_TEST"] == "1"
if updateTesting && licensing {
    fatalError("MACPAPER_UPDATE_TEST=1 cannot be combined with OPENAPPS_LICENSING=1 (scripts/bundle.sh)")
}

var flavourDefines: [SwiftSetting] = []
if licensing { flavourDefines.append(.define("OPENAPPS_LICENSING")) }
if official { flavourDefines.append(.define("OPENAPPS_OFFICIAL")) }
if updateTesting { flavourDefines.append(.define("MACPAPER_UPDATE_TESTING")) }

// The shared licensing rules, records and badge (LICENSING.md).
var appDependencies: [Target.Dependency] = [
    "MacPaperCore",
    .product(name: "OpenAppsLicensing", package: "openapps-licensing"),
]
var packageDependencies: [Package.Dependency] = [.package(path: "../../packages/openapps-licensing")]
if licensing {
    // Dodo Payments, the trial registry, the hardware UUID and the
    // preferences journal: only a build that talks to them links them.
    appDependencies.append(.product(name: "OpenAppsLicensingClients", package: "openapps-licensing"))
}
// The shared in-app updater (RELEASES.md, "In-app updater"); the tests of
// its wiring link it too.
var updaterDependencies: [Target.Dependency] = []
if official {
    packageDependencies.append(.package(path: "../../packages/openapps-updater"))
    updaterDependencies.append(.product(name: "OpenAppsUpdater", package: "openapps-updater"))
}

// The app is main-actor isolated by default: AppKit windows, the status
// item and the panel all live there. The core is not: generators and
// exporters are pure functions the app renders off the main actor.
let appSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)] + flavourDefines

let package = Package(
    name: "MacPaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPaper", targets: ["MacPaper"]),
        .library(name: "MacPaperCore", targets: ["MacPaperCore"]),
        // The screen-saver module, assembled into macPaper.saver by
        // scripts/bundle.sh and installed by the user from Settings.
        .library(name: "MacPaperSaver", type: .dynamic, targets: ["MacPaperSaver"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // The wallpaper document and its generators, pixelize, PNG and SVG
        // export, favorites, the shuffle planner, per-display apply through
        // `DesktopApplier`, the render cache, the notch geometry, the panel
        // state machine and the first-run flags. No UI, no AppKit windows,
        // nothing that touches the live desktop: the real applier is
        // injected by the app only.
        .target(
            name: "MacPaperCore"
        ),
        // The menu-bar app: status item and popover, the notch panel,
        // settings, the hotkey, the login item, the setup guide, licensing,
        // the updater, the debug preview harness.
        .executableTarget(
            name: "MacPaper",
            dependencies: appDependencies + updaterDependencies,
            resources: [.copy("Resources")],
            swiftSettings: appSettings
        ),
        // The `.saver`: a ScreenSaverView over the documents the app keeps,
        // rendered through the core; no dependency on the app target.
        .target(
            name: "MacPaperSaver",
            dependencies: ["MacPaperCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Golden hashes for deterministic seeds, the exporters, the stores
        // with temporary directories, the planner, the applier with a fake,
        // the panel rules. Nothing here touches the desktop.
        .testTarget(
            name: "MacPaperCoreTests",
            dependencies: ["MacPaperCore"]
        ),
        // The app's wiring: preferences round trips, the hotkey value, the
        // fresh-install default and diagnostics text; the licensing wiring
        // against the package's manager with fake stores and clients (the
        // restriction mapping, the badge, LICENSING.md's shared cases run
        // through macPaper's values, every restricted state at the outputs);
        // in an official build also the updater's wiring. No window is
        // opened, no record store read, no network reached.
        .testTarget(
            name: "MacPaperTests",
            dependencies: [
                "MacPaper", "MacPaperCore", "MacPaperSaver",
                .product(name: "OpenAppsLicensing", package: "openapps-licensing"),
            ] + updaterDependencies,
            swiftSettings: flavourDefines
        ),
    ]
)
