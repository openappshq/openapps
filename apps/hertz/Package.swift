// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Official builds set OPENAPPS_LICENSING=1 and OPENAPPS_OFFICIAL=1 (see
// scripts/bundle.sh); source builds compile licensing out entirely. Every
// build links the shared licensing rules (packages/openapps-licensing: the
// badge type the UI carries and the manager the tests drive with fakes);
// only a licensed build links its Dodo, trial registry and preferences
// clients. Nothing is fetched: it is a local package in this repository.
let environment = ProcessInfo.processInfo.environment
let licensing = environment["OPENAPPS_LICENSING"] == "1"
let official = environment["OPENAPPS_OFFICIAL"] == "1"

// Every target is main-actor isolated by default: the collectors are plain
// synchronous code and the app reads them from a main-run-loop timer.
let isolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

var flavourDefines: [SwiftSetting] = []
if licensing { flavourDefines.append(.define("OPENAPPS_LICENSING")) }
if official { flavourDefines.append(.define("OPENAPPS_OFFICIAL")) }
let appSettings = isolation + flavourDefines

// The shared licensing rules, records and badge (LICENSING.md).
var appDependencies: [Target.Dependency] = [
    "HertzCore",
    .product(name: "OpenAppsLicensing", package: "openapps-licensing"),
]
if licensing {
    // Dodo Payments, the trial registry, the hardware UUID and the
    // preferences journal: only a build that talks to them links them.
    appDependencies.append(.product(name: "OpenAppsLicensingClients", package: "openapps-licensing"))
}

let package = Package(
    name: "Hertz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hertz", targets: ["Hertz"]),
        .library(name: "HertzCore", targets: ["HertzCore"]),
    ],
    dependencies: [.package(path: "../../packages/openapps-licensing")],
    targets: [
        // Metric collectors and pure data, no UI. Shared by the app, the
        // verifier and the tests, so what is checked is what ships.
        .target(
            name: "HertzCore",
            swiftSettings: isolation
        ),
        // The menu-bar app: dashboard, settings, the setup guide, licensing.
        .executableTarget(
            name: "Hertz",
            dependencies: appDependencies,
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
        // of LICENSING.md's shared cases run through Hertz's values. Nothing
        // here opens a window, reads the record store or reaches the network.
        // Not main-actor by default: the fakes satisfy nonisolated protocols
        // and the manager runs on its own actor.
        .testTarget(
            name: "HertzTests",
            dependencies: [
                "Hertz", "HertzCore",
                .product(name: "OpenAppsLicensing", package: "openapps-licensing"),
            ],
            swiftSettings: flavourDefines
        ),
    ]
)
