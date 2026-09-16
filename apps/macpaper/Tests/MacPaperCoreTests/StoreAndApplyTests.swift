import Foundation
@testable import MacPaperCore
import Testing

/// A fresh temporary directory per test, removed afterwards.
struct TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Favorites")
struct FavoritesTests {
    @Test("Add, toggle, remove and reload from disk")
    func lifecycle() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appendingPathComponent("favorites.json")
        let store = FavoritesStore(fileURL: file)
        #expect(store.all.isEmpty)
        let a = Wallpaper.starter, b = Wallpaper.starter.reseeded(2)
        try store.add(a)
        #expect(store.contains(a))
        #expect(!store.contains(b))
        // Adding again is one favorite.
        try store.add(a)
        #expect(store.all.count == 1)
        #expect(try store.toggle(b) == true)
        #expect(store.all.map(\.wallpaper) == [b, a], "newest first")
        #expect(try store.toggle(b) == false)
        #expect(store.all.map(\.wallpaper) == [a])
        let reloaded = FavoritesStore(fileURL: file)
        #expect(reloaded.all.map(\.id) == store.all.map(\.id) && reloaded.all.map(\.wallpaper) == store.all.map(\.wallpaper))
        try store.remove(a)
        #expect(store.all.isEmpty)
        try store.remove(a)
    }

    @Test("A write failure leaves the list as it was")
    func writeFailure() {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        // The favorites path is a directory, so the write fails.
        let store = FavoritesStore(fileURL: directory.url)
        #expect(throws: (any Error).self) { try store.add(.starter) }
        #expect(store.all.isEmpty)
    }

    @Test("The applied state records each display's document and the draft")
    func applied() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appendingPathComponent("applied.json")
        let store = AppliedStore(fileURL: file)
        #expect(store.current.byDisplay.isEmpty)
        let date = Date(timeIntervalSince1970: 1_000_000)
        try store.update { state in
            state.set(.starter, for: 1)
            state.set(.starter.reseeded(9), for: 2)
            state.lastApplied = date
            state.draft = .starter.reseeded(3)
        }
        let reloaded = AppliedStore(fileURL: file).current
        #expect(reloaded.wallpaper(for: 1) == .starter)
        #expect(reloaded.wallpaper(for: 2) == Wallpaper.starter.reseeded(9))
        #expect(reloaded.wallpaper(for: 3) == nil)
        #expect(reloaded.lastApplied == date)
        #expect(reloaded.draft == Wallpaper.starter.reseeded(3))
    }
}

@Suite("Imports")
struct ImportTests {
    @Test("An image is copied under its content hash and read back; junk is refused")
    func importImage() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let store = ImportStore(directory: directory.url.appendingPathComponent("imports"))
        let raster = WallpaperRenderer().render(.starter, size: PixelSize(width: 12, height: 8))
        let png = try #require(raster.pngData())
        let reference = try store.importImage(data: png, fileExtension: "png")
        #expect(reference.contentHash == raster.contentHash)
        #expect(reference.fileName.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("imports/\(reference.fileName)").path))
        #expect(store.raster(for: reference) == raster)
        // Another store over the same folder decodes it from disk.
        #expect(ImportStore(directory: directory.url.appendingPathComponent("imports")).raster(for: reference) == raster)
        // The same image again is the same reference, no second copy.
        #expect(try store.importImage(data: png, fileExtension: "png") == reference)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("imports").path).count == 1)
        #expect(throws: ImportStore.ImportError.self) { try store.importImage(data: Data("not an image".utf8), fileExtension: "png") }
        #expect(store.raster(for: ImageReference(fileName: "missing.png", contentHash: "x")) == nil)
    }
}

@Suite("Render cache")
struct RenderCacheTests {
    @Test("Hits, misses, and eviction by bytes and count, least recently used first")
    func lru() {
        let cache = RenderCache(maxBytes: 64 * 3, maxEntries: 10)   // three 4×4 rasters of 64 bytes
        let size = PixelSize(width: 4, height: 4)
        func key(_ seed: UInt64) -> RenderCache.Key { RenderCache.Key(wallpaper: .starter.reseeded(seed), size: size) }
        var made = 0
        for seed in 1...3 { _ = cache.render(key(UInt64(seed))) { made += 1; return Raster(size: size) } }
        #expect(made == 3 && cache.count == 3)
        _ = cache.render(key(1)) { made += 1; return Raster(size: size) }
        #expect(made == 3, "a hit")
        // Touching 1 made 2 the oldest: a fourth evicts 2.
        _ = cache.render(key(4)) { made += 1; return Raster(size: size) }
        #expect(cache.count == 3)
        #expect(cache.raster(for: key(2)) == nil)
        #expect(cache.raster(for: key(1)) != nil)
        #expect(cache.bytes == 3 * 64)
        // A raster over the whole limit is not stored.
        cache.store(Raster(width: 40, height: 40), for: key(5))
        #expect(cache.raster(for: key(5)) == nil)
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytes == 0)
        let counted = RenderCache(maxBytes: .max, maxEntries: 2)
        for seed in 1...3 { counted.store(Raster(size: size), for: key(UInt64(seed))) }
        #expect(counted.count == 2 && counted.raster(for: key(1)) == nil)
    }
}

@Suite("Apply")
struct ApplyTests {
    static let a = DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 16, height: 10), scale: 2, notchWidth: 200, isMain: true)
    static let b = DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 32, height: 20), scale: 1)

    @Test("Scope: this display, all displays, and same-on-all overriding")
    func scope() {
        let displays = [Self.a, Self.b]
        #expect(ApplyScope.plan(.starter, scope: .display(2), displays: displays, sameOnAllDisplays: false) == [Self.b: .starter])
        #expect(ApplyScope.plan(.starter, scope: .display(2), displays: displays, sameOnAllDisplays: true) == [Self.a: .starter, Self.b: .starter])
        #expect(ApplyScope.plan(.starter, scope: .allDisplays, displays: displays, sameOnAllDisplays: false) == [Self.a: .starter, Self.b: .starter])
        #expect(ApplyScope.plan(.starter, scope: .display(9), displays: displays, sameOnAllDisplays: false).isEmpty)
    }

    @Test("Each display gets a new file at its pixel size, the applier is called, old files are pruned")
    func applies() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applier = RecordingApplier()
        let cache = RenderCache()
        let wallpapers = WallpaperApplier(applier: applier, renderer: WallpaperRenderer(), cache: cache, directory: directory.url.appendingPathComponent("applied"), keptPerDisplay: 2)
        let first = try wallpapers.apply([Self.a: .starter, Self.b: .starter])
        #expect(first.map(\.display) == [1, 2])
        #expect(applier.calls.map(\.display) == [1, 2])
        #expect(first[0].url.lastPathComponent == "1-1.png" && first[1].url.lastPathComponent == "2-1.png")
        let raster = try #require(Raster.decode(try Data(contentsOf: first[0].url)))
        #expect(raster.size == PixelSize(width: 32, height: 20), "points × scale")
        #expect(cache.count == 1, "both displays are 32×20 pixels: one render, shared")
        // Applying again writes new files: macOS ignores a changed image at a URL it shows.
        let second = try wallpapers.apply([Self.a: .starter.reseeded(2)])
        #expect(second[0].url.lastPathComponent == "1-2.png")
        let third = try wallpapers.apply([Self.a: .starter.reseeded(3)])
        #expect(third[0].url.lastPathComponent == "1-3.png")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("applied").path).sorted()
        #expect(names == ["1-2.png", "1-3.png", "2-1.png"], "two kept per display")
    }

    @Test("A failing display is reported after the others were applied")
    func failure() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        final class FlakyApplier: DesktopApplier, @unchecked Sendable {
            struct Refused: Error, LocalizedError { var errorDescription: String? { "no such display" } }
            var applied: [DisplayID] = []
            func apply(imageAt url: URL, to display: DisplayID) throws {
                if display == 2 { throw Refused() }
                applied.append(display)
            }
        }
        let applier = FlakyApplier()
        let wallpapers = WallpaperApplier(applier: applier, renderer: WallpaperRenderer(), cache: RenderCache(), directory: directory.url)
        do {
            _ = try wallpapers.apply([Self.a: .starter, Self.b: .starter])
            Issue.record("expected a failure")
        } catch let failure as WallpaperApplier.Failure {
            #expect(failure.applied.map(\.display) == [1])
            #expect(failure.failures.map(\.0) == [2])
            #expect(failure.errorDescription == "Display 2: no such display")
        }
        #expect(applier.applied == [1])
    }
}

@Suite("Shuffle")
struct ShuffleTests {
    static let a = DisplayInfo(id: 1, name: "A", pointSize: CGSize(width: 16, height: 10), scale: 2)
    static let b = DisplayInfo(id: 2, name: "B", pointSize: CGSize(width: 16, height: 10), scale: 2)

    @Test("The schedule is due one interval after the anchor, or after being turned on")
    func schedule() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(ShuffleSchedule(interval: .off, anchor: now).nextDue(now: now) == nil)
        #expect(!ShuffleSchedule(interval: .off, anchor: nil).isDue(now: now))
        let fresh = ShuffleSchedule(interval: .minutes15, anchor: nil)
        #expect(fresh.nextDue(now: now) == now.addingTimeInterval(900))
        #expect(!fresh.isDue(now: now))
        let anchored = ShuffleSchedule(interval: .hour1, anchor: now.addingTimeInterval(-3600))
        #expect(anchored.isDue(now: now))
        #expect(!ShuffleSchedule(interval: .hour1, anchor: now.addingTimeInterval(-3599)).isDue(now: now))
        // Slept through three intervals: one is due, at the same moment.
        #expect(ShuffleSchedule(interval: .minutes15, anchor: now.addingTimeInterval(-3000)).nextDue(now: now) == now.addingTimeInterval(-2100))
        #expect(ShuffleInterval.allCases.map(\.seconds) == [nil, 900, 1800, 3600, 10_800, 21_600, 86_400])
    }

    @Test("Same on all displays picks one document; otherwise each display gets its own, unlike its current")
    func planning() {
        var generator = SeededGenerator(seed: 1)
        let same = ShufflePlanner.plan(displays: [Self.a, Self.b], current: [:], favorites: [], favoritesOnly: false, sameOnAllDisplays: true, using: &generator)
        #expect(same[Self.a] == same[Self.b])
        let current = try! #require(same[Self.a])
        let perDisplay = ShufflePlanner.plan(displays: [Self.a, Self.b], current: [1: current, 2: current], favorites: [], favoritesOnly: false, sameOnAllDisplays: false, using: &generator)
        #expect(perDisplay[Self.a] != perDisplay[Self.b])
        #expect(perDisplay[Self.a] != current && perDisplay[Self.b] != current)
        #expect(ShufflePlanner.plan(displays: [], current: [:], favorites: [], favoritesOnly: false, sameOnAllDisplays: true, using: &generator).isEmpty)
    }

    @Test("Favorites only draws from the favorites, avoiding the current one, and falls back to random with none")
    func favorites() {
        var generator = SeededGenerator(seed: 2)
        let favorites = [Wallpaper.starter, .starter.reseeded(2), .starter.reseeded(3)]
        for _ in 0..<10 {
            let plan = ShufflePlanner.plan(displays: [Self.a], current: [1: .starter], favorites: favorites, favoritesOnly: true, sameOnAllDisplays: true, using: &generator)
            let pick = try! #require(plan[Self.a])
            #expect(favorites.contains(pick) && pick != .starter)
        }
        // One favorite, and it is current: it is picked anyway.
        let only = ShufflePlanner.plan(displays: [Self.a], current: [1: .starter], favorites: [.starter], favoritesOnly: true, sameOnAllDisplays: true, using: &generator)
        #expect(only[Self.a] == .starter)
        let none = ShufflePlanner.plan(displays: [Self.a], current: [:], favorites: [], favoritesOnly: true, sameOnAllDisplays: true, using: &generator)
        #expect(none[Self.a] != nil)
        // Favorites off ignores them.
        let random = ShufflePlanner.plan(displays: [Self.a], current: [:], favorites: favorites, favoritesOnly: false, sameOnAllDisplays: true, using: &generator)
        #expect(!favorites.contains(random[Self.a]!))
    }
}
