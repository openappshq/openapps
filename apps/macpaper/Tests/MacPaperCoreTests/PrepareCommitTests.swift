import Foundation
@testable import MacPaperCore
import Testing

/// The applier in two halves: `prepare` renders and writes without a
/// desktop call, `commit` is the only desktop call, `discard` takes an
/// uncommitted file back out of the folder and the manifest.
@Suite("Prepare, commit, discard")
struct PrepareCommitTests {
    static let a = DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 16, height: 10), scale: 2, notchWidth: 200, isMain: true)
    static let b = DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 32, height: 20), scale: 1)

    @Test("Prepare touches no desktop; commit does, one display at a time; discard removes the rest")
    func halves() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applier = RecordingApplier()
        let applied = directory.url.appendingPathComponent("applied", isDirectory: true)
        let wallpapers = WallpaperApplier(applier: applier, renderer: WallpaperRenderer(), cache: RenderCache(), directory: applied, keptPerDisplay: 2)
        let prepared = try wallpapers.prepare([Self.a: .starter, Self.b: .starter])
        #expect(prepared.images.map(\.display) == [1, 2])
        #expect(prepared.failures.isEmpty)
        #expect(applier.calls.isEmpty, "nothing on the desktop yet")
        var names = try FileManager.default.contentsOfDirectory(atPath: applied.path).sorted()
        #expect(names == ["1-1.png", "2-1.png", "manifest.json"])

        let first = try wallpapers.commit(prepared.images[0])
        #expect(applier.calls.map(\.display) == [1])
        #expect(first == AppliedImage(display: 1, wallpaper: .starter, url: prepared.images[0].url))

        wallpapers.discard(prepared.images[1])
        #expect(applier.calls.map(\.display) == [1])
        names = try FileManager.default.contentsOfDirectory(atPath: applied.path).sorted()
        #expect(names == ["1-1.png", "manifest.json"])
        #expect(AppliedManifest.load(in: applied).names(for: 2).isEmpty, "the manifest forgets it")
        #expect(AppliedManifest.load(in: applied).names(for: 1) == ["1-1.png"])

        // The next apply for display 2 starts its counter where the discarded file left off.
        let again = try wallpapers.prepare([Self.b: .starter.reseeded(2)])
        #expect(again.images[0].url.lastPathComponent == "2-1.png")
        _ = try wallpapers.commit(again.images[0])
        #expect(applier.calls.map(\.display) == [1, 2])
    }

    @Test("Discard leaves foreign files alone and forgets only its own entry")
    func discardOwnership() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applied = directory.url.appendingPathComponent("applied", isDirectory: true)
        let wallpapers = WallpaperApplier(applier: RecordingApplier(), renderer: WallpaperRenderer(), cache: RenderCache(), directory: applied)
        let prepared = try wallpapers.prepare([Self.a: .starter])
        let url = prepared.images[0].url
        // Something else replaces the file with a symlink before the discard.
        try FileManager.default.removeItem(at: url)
        let outside = directory.url.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        wallpapers.discard(prepared.images[0])
        #expect(FileManager.default.fileExists(atPath: outside.path), "the link's target is untouched")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil, "the link itself is left alone")
        #expect(AppliedManifest.load(in: applied).names(for: 1).isEmpty)
    }

    @Test("apply is prepare then commit for every display, with the same files and calls as before")
    func composed() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applier = RecordingApplier()
        let wallpapers = WallpaperApplier(applier: applier, renderer: WallpaperRenderer(), cache: RenderCache(), directory: directory.url.appendingPathComponent("applied"))
        let images = try wallpapers.apply([Self.a: .starter, Self.b: .starter])
        #expect(images.map(\.display) == [1, 2])
        #expect(applier.calls.map(\.url.lastPathComponent) == ["1-1.png", "2-1.png"])
        struct Refused: Error {}
        applier.failure = Refused()
        #expect(throws: WallpaperApplier.Failure.self) { try wallpapers.apply([Self.a: .starter.reseeded(2)]) }
    }
}
