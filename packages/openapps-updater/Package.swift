// swift-tools-version: 6.0
import PackageDescription

// The in-app updater every OpenApps HQ Swift app compiles into its official
// builds (RELEASES.md, "In-app updater"): a signed appcast, an Ed25519-signed
// zip, verification with the public key pinned in the app, and an atomic
// swap of the installed bundle. No dependencies; nothing app-specific: the
// app injects its feed, key, identity and strings.
let package = Package(
    name: "openapps-updater",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenAppsUpdater", targets: ["OpenAppsUpdater"]),
    ],
    targets: [
        .target(name: "OpenAppsUpdater"),
        .testTarget(name: "OpenAppsUpdaterTests", dependencies: ["OpenAppsUpdater"]),
    ],
    swiftLanguageModes: [.v6]
)
