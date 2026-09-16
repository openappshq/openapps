// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacPaper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacPaperCore", targets: ["MacPaperCore"]),
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
        // Golden hashes for deterministic seeds, the exporters, the stores
        // with temporary directories, the planner, the applier with a fake,
        // the panel rules. Nothing here touches the desktop.
        .testTarget(
            name: "MacPaperCoreTests",
            dependencies: ["MacPaperCore"]
        ),
    ]
)
