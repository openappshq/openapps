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
// and the setup guide stay off and test hooks are compiled in. Never set for
// a release; verify-release.sh checks. Never with licensing: the test
// variant must not link the record store, the registry or Dodo's client,
// and its licensing-off launch path is the one that knows to skip the
// login item.
let updateTesting = official && environment["HERTZ_UPDATE_TEST"] == "1"
if updateTesting && licensing {
    fatalError("HERTZ_UPDATE_TEST=1 cannot be combined with OPENAPPS_LICENSING=1 (scripts/bundle.sh, scripts/update-e2e.sh)")
}

// Every target is main-actor isolated by default: the collectors are plain
// synchronous code and the app reads them from a main-run-loop timer.
let isolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

var flavourDefines: [SwiftSetting] = []
if licensing { flavourDefines.append(.define("OPENAPPS_LICENSING")) }
if official { flavourDefines.append(.define("OPENAPPS_OFFICIAL")) }
if updateTesting { flavourDefines.append(.define("HERTZ_UPDATE_TESTING")) }
let appSettings = isolation + flavourDefines

// The shared licensing rules, records and badge (LICENSING.md).
var appDependencies: [Target.Dependency] = [
    "HertzCore",
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

let package = Package(
    name: "Hertz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hertz", targets: ["Hertz"]),
        .library(name: "HertzCore", targets: ["HertzCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // Metric collectors and pure data, no UI. Shared by the app, the
        // verifier and the tests, so what is checked is what ships.
        .target(
            name: "HertzCore",
            swiftSettings: isolation
        ),
        // The menu-bar app: dashboard, settings, the setup guide, licensing,
        // the updater.
        .executableTarget(
            name: "Hertz",
            dependencies: appDependencies + updaterDependencies,
            resources: [.copy("Resources")],
            swiftSettings: appSettings
        ),
        // Dev-only verification against df/vm_stat/top/ps/pmset/ioreg:
        // `swift run HertzVerify`. Never bundled into the shipped app.
        .executableTarget(
            name: "HertzVerify",
            dependencies: ["HertzCore"],
            swiftSettings: isolation
        ),
        // Pure logic only: health score, process tree, diagnosis, formatting,
        // cleanup path rules, first-run flags. Nothing here touches the live
        // system. Not main-actor by default: XCTestCase's overridable hooks
        // are nonisolated. Each test method is marked @MainActor itself.
        .testTarget(
            name: "HertzCoreTests",
            dependencies: ["HertzCore"]
        ),
        // The app's licensing wiring against the package's manager with fake
        // stores and clients: the restriction mapping, the badge, and a few
        // of LICENSING.md's shared cases run through Hertz's values; in an
        // official build also the updater's wiring (the fresh-install
        // default, the footer's hint). Nothing here opens a window, reads
        // the record store or reaches the network. Not main-actor by
        // default: the fakes satisfy nonisolated protocols and the manager
        // runs on its own actor.
        .testTarget(
            name: "HertzTests",
            dependencies: [
                "Hertz", "HertzCore",
                .product(name: "OpenAppsLicensing", package: "openapps-licensing"),
            ] + updaterDependencies,
            swiftSettings: flavourDefines
        ),
    ]
)
