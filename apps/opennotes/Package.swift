// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh); source builds compile licensing and the updater out
// entirely. The flavour defines are the same as Hertz's and macPaper's so
// the licensing and updater wiring (the parity ticket, LICENSING.md and
// RELEASES.md) drops into the `#if` seams left in the app; until it does,
// neither shared package is linked, and a licensed or official build has
// nothing to compile in.
let environment = ProcessInfo.processInfo.environment
let licensing = environment["OPENAPPS_LICENSING"] == "1"
let official = environment["OPENAPPS_OFFICIAL"] == "1"
// Local update tests only (scripts/update-e2e.sh): the login-item default
// and the setup guide stay off and test hooks are compiled in. Never set
// for a release; verify-release.sh checks. Never with licensing.
let updateTesting = official && environment["OPENNOTES_UPDATE_TEST"] == "1"
if updateTesting && licensing {
    fatalError("OPENNOTES_UPDATE_TEST=1 cannot be combined with OPENAPPS_LICENSING=1 (scripts/bundle.sh)")
}

var flavourDefines: [SwiftSetting] = []
if licensing { flavourDefines.append(.define("OPENAPPS_LICENSING")) }
if official { flavourDefines.append(.define("OPENAPPS_OFFICIAL")) }
if updateTesting { flavourDefines.append(.define("OPENNOTES_UPDATE_TESTING")) }

// Every target is main-actor isolated by default: the store is called from
// the app's windows, the watcher hops to the main queue, and the pure
// value types are marked nonisolated where they are declared.
let isolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
let appSettings = isolation + flavourDefines

let package = Package(
    name: "OpenNotes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenNotes", targets: ["OpenNotes"]),
        .library(name: "OpenNotesCore", targets: ["OpenNotesCore"]),
    ],
    targets: [
        // The note model and its file format, the Markdown-lite styler,
        // the folder store and watcher, search, export, archive and undo,
        // the deck's rules and geometry, the hotkey value and the first-run
        // flags. No UI, no AppKit windows. Shared by the app and the tests,
        // so what is tested is what ships.
        .target(
            name: "OpenNotesCore",
            swiftSettings: isolation
        ),
        // The menu-bar app: the deck window per display, the editor, All
        // Notes, Settings, the hotkey, the login item, the debug preview
        // harness.
        .executableTarget(
            name: "OpenNotes",
            dependencies: ["OpenNotesCore"],
            resources: [.copy("Resources")],
            swiftSettings: appSettings
        ),
        // The core against temporary folders only: the file format, the
        // store's reads, writes, conflicts and renames, the styler, search,
        // export, archive and undo, the deck rules and layout, the first-run
        // flags. Nothing here touches the user's notes folder.
        .testTarget(
            name: "OpenNotesCoreTests",
            dependencies: ["OpenNotesCore"]
        ),
        // The app's wiring: preferences round trips, the editor's styling on
        // a text storage (attribute-only), the deck controller's effects
        // against the store, the diagnostics text, the fresh-install
        // default. No window is opened, no login item registered, no
        // hotkey installed.
        .testTarget(
            name: "OpenNotesTests",
            dependencies: ["OpenNotes", "OpenNotesCore"],
            swiftSettings: flavourDefines
        ),
    ]
)
