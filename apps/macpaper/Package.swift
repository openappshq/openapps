// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Official builds will set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh) once the licensing ticket wires the shared packages
// in; today both flags only define their compilation conditions so the
// seams (`#if OPENAPPS_LICENSING`) compile in every flavour, and nothing
// outside this directory is linked. Source builds compile licensing and the
// updater out entirely.
let environment = ProcessInfo.processInfo.environment
let licensing = environment["OPENAPPS_LICENSING"] == "1"
let official = environment["OPENAPPS_OFFICIAL"] == "1"
// Local update tests only (a later ticket's scripts/update-e2e.sh): the
// login-item default stays off and test hooks are compiled in. Never set
// for a release; verify-release.sh checks.
let updateTesting = official && environment["MACPAPER_UPDATE_TEST"] == "1"
if updateTesting && licensing {
    fatalError("MACPAPER_UPDATE_TEST=1 cannot be combined with OPENAPPS_LICENSING=1 (scripts/bundle.sh)")
}

var flavourDefines: [SwiftSetting] = []
if licensing { flavourDefines.append(.define("OPENAPPS_LICENSING")) }
if official { flavourDefines.append(.define("OPENAPPS_OFFICIAL")) }
if updateTesting { flavourDefines.append(.define("MACPAPER_UPDATE_TESTING")) }

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
        // settings, the hotkey, the login item, the debug preview harness.
        .executableTarget(
            name: "MacPaper",
            dependencies: ["MacPaperCore"],
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
        // fresh-install default and diagnostics text. No window is opened.
        .testTarget(
            name: "MacPaperTests",
            dependencies: ["MacPaper", "MacPaperCore", "MacPaperSaver"],
            swiftSettings: flavourDefines
        ),
    ]
)
