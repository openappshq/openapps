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
        let reference = try store.importImage(data: png)
        #expect(reference.contentHash == raster.contentHash)
        #expect(reference.fileName.hasSuffix(".png"))
        #expect(ImageReference.isValidFileName(reference.fileName))
        #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("imports/\(reference.fileName)").path))
        #expect(store.raster(for: reference) == raster)
        // Another store over the same folder decodes it from disk.
        #expect(ImportStore(directory: directory.url.appendingPathComponent("imports")).raster(for: reference) == raster)
        // The same image again is the same reference, no second copy.
        #expect(try store.importImage(data: png) == reference)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("imports").path).count == 1)
        #expect(throws: ImportStore.ImportError.self) { try store.importImage(data: Data("not an image".utf8)) }
        #expect(store.raster(for: ImageReference(fileName: "0123456789abcdef.png", contentHash: String(repeating: "0", count: 64))) == nil)
        #expect(!store.hasImage(for: ImageReference(fileName: "0123456789abcdef.png", contentHash: String(repeating: "0", count: 64))))
    }

    @Test("A large source is scaled down while decoding, never held whole")
    func bounded() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let store = ImportStore(directory: directory.url.appendingPathComponent("imports"))
        let big = WallpaperRenderer().render(.starter, size: PixelSize(width: 600, height: 200))
        let reference = try store.importImage(data: try #require(big.pngData()), maxPixelSize: 300)
        let stored = try #require(store.raster(for: reference))
        #expect(stored.size == PixelSize(width: 300, height: 100))
        // The file on disk is the bounded PNG, not the original bytes.
        let onDisk = try #require(Raster.decode(try Data(contentsOf: directory.url.appendingPathComponent("imports/\(reference.fileName)"))))
        #expect(onDisk.size == PixelSize(width: 300, height: 100))
        #expect(Raster.decode(at: directory.url.appendingPathComponent("nothing.png"), maxPixelSize: 10) == nil)
    }

    @Test("The decoded cache is bounded by bytes, least recently used first")
    func cacheBound() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        // Three 8×8 rasters are 256 bytes each; room for two.
        let store = ImportStore(directory: directory.url.appendingPathComponent("imports"), maxCacheBytes: 600)
        var references: [ImageReference] = []
        for seed in 1...3 {
            let raster = WallpaperRenderer().render(.starter.reseeded(UInt64(seed)), size: PixelSize(width: 8, height: 8))
            references.append(try store.importImage(data: try #require(raster.pngData())))
        }
        #expect(store.cachedCount == 2 && store.cachedBytes == 512)
        // The evicted one still resolves from disk.
        #expect(store.raster(for: references[0]) != nil)
        #expect(store.cachedCount == 2)
    }

    @Test("References that leave the folder, symlinks and wrong hashes resolve to nothing")
    func containment() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let imports = directory.url.appendingPathComponent("imports")
        let store = ImportStore(directory: imports)
        let raster = WallpaperRenderer().render(.starter, size: PixelSize(width: 8, height: 8))
        let png = try #require(raster.pngData())
        let reference = try store.importImage(data: png)
        // A decodable image outside the folder, reached by a traversal name: refused at decoding.
        let outside = directory.url.appendingPathComponent("outside.png")
        try png.write(to: outside)
        let traversal = "{\"fileName\":\"../outside.png\",\"contentHash\":\"\(raster.contentHash)\"}"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ImageReference.self, from: Data(traversal.utf8)) }
        for bad in ["/etc/passwd", "..", ".hidden.png", "a.b.png", "UPPER0123456789.png", "0123456789abcdef.png.", "0123456789abcdef"] {
            #expect(!ImageReference.isValidFileName(bad), Comment(rawValue: bad))
        }
        #expect(!ImageReference.isValidHash("x"))
        // A symlink inside the folder pointing outside is refused.
        let link = imports.appendingPathComponent("0123456789abcdef01234567.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(store.raster(for: ImageReference(fileName: "0123456789abcdef01234567.png", contentHash: raster.contentHash)) == nil)
        // The right file under a wrong hash is refused too.
        #expect(store.raster(for: ImageReference(fileName: reference.fileName, contentHash: String(repeating: "a", count: 64))) == nil)
        // A directory under a valid name is refused.
        let dir = imports.appendingPathComponent("abcdef0123456789abcdef01.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(store.raster(for: ImageReference(fileName: "abcdef0123456789abcdef01.png", contentHash: raster.contentHash)) == nil)
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
        #expect(cache.count == 2, "both displays are 32×20 pixels, but one has a notch: two contexts")
        // Applying again writes new files: macOS ignores a changed image at a URL it shows.
        let second = try wallpapers.apply([Self.a: .starter.reseeded(2)])
        #expect(second[0].url.lastPathComponent == "1-2.png")
        let third = try wallpapers.apply([Self.a: .starter.reseeded(3)])
        #expect(third[0].url.lastPathComponent == "1-3.png")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("applied").path).sorted()
        #expect(names == ["1-2.png", "1-3.png", "2-1.png", "manifest.json"], "two kept per display")
    }

    @Test("Pruning deletes only what the applier wrote: foreign files, directories and symlinks with matching names stay")
    func ownership() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applied = directory.url.appendingPathComponent("applied", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: applied, withIntermediateDirectories: true)
        // A directory named like an applied file, holding something valuable.
        let planted = applied.appendingPathComponent("1-0.png", isDirectory: true)
        try fm.createDirectory(at: planted, withIntermediateDirectories: true)
        try Data("valuable".utf8).write(to: planted.appendingPathComponent("keep.txt"))
        // A foreign regular file under the very next name, and a symlink under the one after.
        let foreign = applied.appendingPathComponent("1-1.png")
        try Data("foreign".utf8).write(to: foreign)
        let outside = directory.url.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let link = applied.appendingPathComponent("1-2.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        let wallpapers = WallpaperApplier(applier: RecordingApplier(), renderer: WallpaperRenderer(), cache: RenderCache(), directory: applied, keptPerDisplay: 2)
        var names: [String] = []
        for seed in 1...4 {
            let images = try wallpapers.apply([Self.a: .starter.reseeded(UInt64(seed))])
            names.append(images[0].url.lastPathComponent)
        }
        #expect(names == ["1-3.png", "1-4.png", "1-5.png", "1-6.png"], "the taken names were skipped, never overwritten")
        let remaining = try fm.contentsOfDirectory(atPath: applied.path).sorted()
        #expect(remaining == ["1-0.png", "1-1.png", "1-2.png", "1-5.png", "1-6.png", "manifest.json"])
        #expect(try Data(contentsOf: planted.appendingPathComponent("keep.txt")) == Data("valuable".utf8))
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test("A manifest entry that stopped being the applier's regular file is left alone")
    func swappedEntry() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applied = directory.url.appendingPathComponent("applied", isDirectory: true)
        let wallpapers = WallpaperApplier(applier: RecordingApplier(), renderer: WallpaperRenderer(), cache: RenderCache(), directory: applied, keptPerDisplay: 1)
        let first = try wallpapers.apply([Self.a: .starter])[0].url
        // Someone replaced the applied file with a directory, then a symlink.
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: first.appendingPathComponent("inside"))
        _ = try wallpapers.apply([Self.a: .starter.reseeded(2)])
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("inside").path), "the directory under the old name survived pruning")
        let realDirectory = applied.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(!WallpaperApplier.isOwnedRegularFile(first, inside: realDirectory))
        let elsewhere = directory.url.appendingPathComponent("elsewhere.png")
        try Data("e".utf8).write(to: elsewhere)
        let link = applied.appendingPathComponent("1-9.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(!WallpaperApplier.isOwnedRegularFile(link, inside: realDirectory), "a symlink is not owned")
        #expect(!WallpaperApplier.isOwnedRegularFile(elsewhere, inside: realDirectory), "outside the directory")
    }

    @Test("An applied directory that is a symbolic link is refused")
    func redirectedDirectory() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = directory.url.appendingPathComponent("applied")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let wallpapers = WallpaperApplier(applier: RecordingApplier(), renderer: WallpaperRenderer(), cache: RenderCache(), directory: link)
        #expect(throws: WallpaperApplier.ApplyError.self) { try wallpapers.apply([Self.a: .starter]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
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
            func currentImageURL(for display: DisplayID) -> URL? { nil }
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
