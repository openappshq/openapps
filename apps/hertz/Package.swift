// swift-tools-version: 6.2
import PackageDescription

// Every target is main-actor isolated by default: the collectors are plain
// synchronous code and the app reads them from a main-run-loop timer.
let isolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Hertz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hertz", targets: ["Hertz"]),
        .library(name: "HertzCore", targets: ["HertzCore"]),
    ],
    targets: [
        // Metric collectors and pure data, no UI. Shared by the app, the
        // verifier and the tests, so what is checked is what ships.
        .target(
            name: "HertzCore",
            swiftSettings: isolation
        ),
        // The menu-bar app: dashboard, settings, welcome window.
        .executableTarget(
            name: "Hertz",
            dependencies: ["HertzCore"],
            resources: [.copy("Resources")],
            swiftSettings: isolation
        ),
        // Dev-only verification against df/vm_stat/top/ps/pmset/ioreg:
        // `swift run HertzVerify`. Never bundled into the shipped app.
        .executableTarget(
            name: "HertzVerify",
            dependencies: ["HertzCore"],
            swiftSettings: isolation
        ),
        // Pure logic only: health score, process tree, diagnosis, formatting,
        // cleanup path rules. Nothing here touches the live system.
        // Not main-actor by default: XCTestCase's overridable hooks are
        // nonisolated. Each test method is marked @MainActor itself.
        .testTarget(
            name: "HertzCoreTests",
            dependencies: ["HertzCore"]
        ),
    ]
)
