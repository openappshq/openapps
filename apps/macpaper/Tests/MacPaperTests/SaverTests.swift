import Foundation
@testable import MacPaper
import MacPaperCore
import MacPaperSaver
import Testing

/// The screen saver: its install never removes what is not macPaper's,
/// and its playback restarts cleanly when the frames change.
@MainActor
struct SaverTests {

    /// A fake `.saver` at `url`: `Contents/Info.plist` with the given
    /// identity and a marker file naming the version.
    private static func plantSaver(at url: URL, bundleID: String, principal: String = SaverInstaller.principalClass, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": bundleID, "NSPrincipalClass": principal]
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try marker.write(to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
    }

    private static func marker(at url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    private static func leftovers(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".macPaper.saver.") }
    }

    @Test("Reinstall never removes a directory that is not macPaper's saver")
    func installerRefusesForeign() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-saver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/macPaper.saver")
        try Self.plantSaver(at: source, bundleID: SaverInstaller.bundleIdentifier, marker: "new")
        let folder = root.appendingPathComponent("Screen Savers")
        let destination = folder.appendingPathComponent(SaverInstaller.name)
        // Someone else's bundle under our name.
        try Self.plantSaver(at: destination, bundleID: "com.example.other", marker: "theirs")
        let installer = SaverInstaller(source: source, destination: destination)
        #expect(!installer.isInstalled)
        #expect(throws: SaverInstaller.InstallError.foreignDestination) { try installer.install() }
        #expect(Self.marker(at: destination) == "theirs" && Self.leftovers(in: folder).isEmpty)
        // A symbolic link under our name, even to our own bundle.
        try FileManager.default.removeItem(at: destination)
        let elsewhere = root.appendingPathComponent("elsewhere/macPaper.saver")
        try Self.plantSaver(at: elsewhere, bundleID: SaverInstaller.bundleIdentifier, marker: "linked")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
        #expect(throws: SaverInstaller.InstallError.destinationIsSymlink) { try installer.install() }
        #expect(Self.marker(at: elsewhere) == "linked" && (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil)
        #expect(!installer.isInstalled, "a link is never reported as installed")
    }

    @Test("A failed copy leaves the installed saver exactly as it was; a good one replaces it with no leftovers")
    func installerStagesAndSwaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-saver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Screen Savers")
        let destination = folder.appendingPathComponent(SaverInstaller.name)
        try Self.plantSaver(at: destination, bundleID: SaverInstaller.bundleIdentifier, marker: "old")
        // The source is missing: the copy fails before anything moves.
        let missing = SaverInstaller(source: root.appendingPathComponent("nowhere/macPaper.saver"), destination: destination)
        #expect(missing.isInstalled)
        #expect(throws: SaverInstaller.InstallError.self) { try missing.install() }
        #expect(Self.marker(at: destination) == "old" && Self.leftovers(in: folder).isEmpty)
        // The source is a bundle that is not ours: staged, refused, gone.
        let impostor = root.appendingPathComponent("impostor/macPaper.saver")
        try Self.plantSaver(at: impostor, bundleID: "com.example.other", marker: "impostor")
        #expect(throws: SaverInstaller.InstallError.stagedBundleInvalid) { try SaverInstaller(source: impostor, destination: destination).install() }
        #expect(Self.marker(at: destination) == "old" && Self.leftovers(in: folder).isEmpty)
        // A verified newer bundle replaces the old one.
        let source = root.appendingPathComponent("source/macPaper.saver")
        try Self.plantSaver(at: source, bundleID: SaverInstaller.bundleIdentifier, marker: "new")
        try SaverInstaller(source: source, destination: destination).install()
        #expect(Self.marker(at: destination) == "new" && Self.leftovers(in: folder).isEmpty)
        #expect(SaverInstaller(source: source, destination: destination).isInstalled)
        // No source at all (a `swift build`): reported, nothing touched.
        #expect(throws: SaverInstaller.InstallError.noSource) { try SaverInstaller(source: nil, destination: destination).install() }
        #expect(Self.marker(at: destination) == "new")
    }

    // MARK: Saver playback

    @Test("The saver's player restarts from the first frame when the frames change, and never indexes past a smaller set")
    func saverPlayer() {
        let start = Date(timeIntervalSince1970: 1_000)
        var player = SaverPlayer(now: start, holdSeconds: 10, fadeSeconds: 2)
        player.replaceFrames(count: 4, now: start)
        #expect(player.currentIndex == 0 && player.fadingOutIndex == nil)
        var moved = player.tick(now: start.addingTimeInterval(5), interval: 1)
        #expect(!moved, "holding")
        // Three switches: the fade starts on the third frame's index.
        for step in 1...3 {
            moved = player.tick(now: start.addingTimeInterval(Double(step) * 10), interval: 1)
            #expect(moved)
            while player.blend < 1 { _ = player.tick(now: start.addingTimeInterval(Double(step) * 10 + 1), interval: 1) }
        }
        #expect(player.currentIndex == 3)
        // Mid-fade, then a restart delivers two frames: back to zero, settled.
        moved = player.tick(now: start.addingTimeInterval(40), interval: 0.5)
        #expect(moved)
        #expect(player.currentIndex == 0 && player.fadingOutIndex == 3 && player.blend < 1)
        player.replaceFrames(count: 2, now: start.addingTimeInterval(40))
        #expect(player.currentIndex == 0 && player.fadingOutIndex == nil && player.blend == 1)
        #expect(player.lastSwitch == start.addingTimeInterval(40), "the hold restarts")
        // Empty: nothing to draw, no switching.
        player.replaceFrames(count: 0, now: start)
        moved = player.tick(now: start.addingTimeInterval(100), interval: 1)
        #expect(player.currentIndex == nil && !moved)
        #expect(MacPaperSaverView.maxFrames <= 4, "a few full-size frames at most")
    }
}
