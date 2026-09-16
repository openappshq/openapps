// swift-tools-version: 6.0
import PackageDescription

// The licensing every OpenApps HQ Swift app compiles into its official
// builds (LICENSING.md): the rules, the in-app trial, the encrypted record
// store and the one-line status badge in `OpenAppsLicensing`, and the live
// Dodo Payments client, trial registry client, hardware identity and
// preferences journal in `OpenAppsLicensingClients`. No dependencies;
// nothing app-specific: the app injects its id, name, products, hosts and
// preferences suite. A build with licensing compiled out links only the
// first product (its badge type is what the app's UI carries), never the
// clients.
let package = Package(
    name: "openapps-licensing",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenAppsLicensing", targets: ["OpenAppsLicensing"]),
        .library(name: "OpenAppsLicensingClients", targets: ["OpenAppsLicensingClients"]),
    ],
    targets: [
        .target(name: "OpenAppsLicensing"),
        .target(name: "OpenAppsLicensingClients", dependencies: ["OpenAppsLicensing"]),
        .testTarget(
            name: "OpenAppsLicensingTests",
            dependencies: ["OpenAppsLicensing", "OpenAppsLicensingClients"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
