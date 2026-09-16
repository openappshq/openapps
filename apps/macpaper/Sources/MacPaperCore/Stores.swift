import Foundation

/// Where the app keeps its files: `~/Library/Application Support/OpenApps/macpaper/`,
/// the same root the licensing record store uses for every OpenApps app.
///
/// - `favorites.json`: the favorites
/// - `applied.json`: the document each display shows
/// - `imports/<hash>.<ext>`: imported images for Pixelize
/// - `applied/<display>-<n>.png`: the files handed to `NSWorkspace`
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard(appID: String = "macpaper") -> AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return AppPaths(root: support.appendingPathComponent("OpenApps/\(appID)", isDirectory: true))
    }

    public var favorites: URL { root.appendingPathComponent("favorites.json") }
    public var applied: URL { root.appendingPathComponent("applied.json") }
    public var imports: URL { root.appendingPathComponent("imports", isDirectory: true) }
    public var appliedImages: URL { root.appendingPathComponent("applied", isDirectory: true) }

    /// The default export folder: `~/Pictures/macPaper`.
    public static var defaultExportFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("macPaper", isDirectory: true)
    }
}

/// A JSON file that is read once and rewritten atomically on every change.
/// Values are plain `Codable` structs; the file is pretty-printed with
/// sorted keys so a diff of it reads.
struct JSONFile<Value: Codable & Sendable>: Sendable {
    let url: URL

    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.store.decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.store.encode(value).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var store: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var store: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Favorites

public struct Favorite: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var wallpaper: Wallpaper
    public let addedAt: Date

    public init(id: UUID = UUID(), wallpaper: Wallpaper, addedAt: Date = Date()) {
        self.id = id
        self.wallpaper = wallpaper
        self.addedAt = addedAt
    }
}

/// The favorites, newest first, in `favorites.json`. A favorite is the
/// document, not a render. Membership is by document content: the same
/// generator, parameters, seed and grain is the same favorite. Every change
/// is written before it is reported; a write that fails throws and leaves
/// the list as it was.
public final class FavoritesStore: @unchecked Sendable {
    private struct File: Codable, Sendable {
        var version = 1
        var favorites: [Favorite]
    }

    private let file: JSONFile<File>
    private let lock = NSLock()
    private var favorites: [Favorite]

    public init(fileURL: URL) {
        file = JSONFile(url: fileURL)
        favorites = (try? file.load())?.favorites ?? []
    }

    public var all: [Favorite] {
        lock.withLock { favorites }
    }

    public func contains(_ wallpaper: Wallpaper) -> Bool {
        lock.withLock { favorites.contains { $0.wallpaper == wallpaper } }
    }

    /// Adds the document unless it is one already; returns the favorite.
    @discardableResult
    public func add(_ wallpaper: Wallpaper, at date: Date = Date()) throws -> Favorite {
        try lock.withLock {
            if let existing = favorites.first(where: { $0.wallpaper == wallpaper }) { return existing }
            let favorite = Favorite(wallpaper: wallpaper, addedAt: date)
            var next = favorites
            next.insert(favorite, at: 0)
            try file.save(File(favorites: next))
            favorites = next
            return favorite
        }
    }

    public func remove(_ wallpaper: Wallpaper) throws {
        try lock.withLock {
            let next = favorites.filter { $0.wallpaper != wallpaper }
            guard next.count != favorites.count else { return }
            try file.save(File(favorites: next))
            favorites = next
        }
    }

    /// Adds when absent, removes when present; returns whether it is a
    /// favorite afterwards.
    @discardableResult
    public func toggle(_ wallpaper: Wallpaper) throws -> Bool {
        if contains(wallpaper) {
            try remove(wallpaper)
            return false
        }
        try add(wallpaper)
        return true
    }
}

// MARK: - Applied documents

/// Which document each display shows, by display id, in `applied.json`,
/// so the panel opens on the current wallpaper after a relaunch. The
/// `lastApplied` date drives the shuffle schedule.
public struct AppliedState: Codable, Hashable, Sendable {
    public var byDisplay: [String: Wallpaper]
    public var lastApplied: Date?
    /// The document the panel edits, applied or not.
    public var draft: Wallpaper?

    public init(byDisplay: [String: Wallpaper] = [:], lastApplied: Date? = nil, draft: Wallpaper? = nil) {
        self.byDisplay = byDisplay
        self.lastApplied = lastApplied
        self.draft = draft
    }

    public func wallpaper(for display: DisplayID) -> Wallpaper? {
        byDisplay[String(display)]
    }

    public mutating func set(_ wallpaper: Wallpaper, for display: DisplayID) {
        byDisplay[String(display)] = wallpaper
    }
}

public final class AppliedStore: @unchecked Sendable {
    private let file: JSONFile<AppliedState>
    private let lock = NSLock()
    private var state: AppliedState

    public init(fileURL: URL) {
        file = JSONFile(url: fileURL)
        state = (try? file.load()) ?? AppliedState()
    }

    public var current: AppliedState {
        lock.withLock { state }
    }

    public func update(_ change: (inout AppliedState) -> Void) throws {
        try lock.withLock {
            var next = state
            change(&next)
            try file.save(next)
            state = next
        }
    }
}

// MARK: - Imported images

/// Imported images for Pixelize, copied into `imports/` under their content
/// hash so a favorite keeps working after the original moves. Decoded on
/// demand and kept in memory by reference while the app runs.
public final class ImportStore: ImageSource, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var cache: [ImageReference: Raster] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Copies the file in (a PNG, JPEG, HEIC, TIFF… anything ImageIO reads)
    /// and returns the reference a document stores. Throws when the image
    /// cannot be decoded; nothing is copied then.
    public func importImage(at url: URL) throws -> ImageReference {
        let data = try Data(contentsOf: url)
        return try importImage(data: data, fileExtension: url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased())
    }

    public func importImage(data: Data, fileExtension: String) throws -> ImageReference {
        guard let raster = Raster.decode(data) else { throw ImportError.undecodable }
        let hash = raster.contentHash
        let fileName = "\(hash.prefix(24)).\(fileExtension)"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        let reference = ImageReference(fileName: fileName, contentHash: hash)
        lock.withLock { cache[reference] = raster }
        return reference
    }

    public func raster(for reference: ImageReference) -> Raster? {
        if let cached = lock.withLock({ cache[reference] }) { return cached }
        let url = directory.appendingPathComponent(reference.fileName)
        guard let data = try? Data(contentsOf: url), let raster = Raster.decode(data) else { return nil }
        lock.withLock { cache[reference] = raster }
        return raster
    }

    public enum ImportError: Error, LocalizedError {
        case undecodable

        public var errorDescription: String? {
            "The file is not an image macOS can read."
        }
    }
}

// MARK: - Render cache

/// The last renders by document and size, bounded by bytes and count; the
/// least recently used goes first. Full-size renders are a few dozen
/// megabytes each, so the default keeps three or four of them.
public final class RenderCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let wallpaper: Wallpaper
        public let size: PixelSize

        public init(wallpaper: Wallpaper, size: PixelSize) {
            self.wallpaper = wallpaper
            self.size = size
        }
    }

    public let maxBytes: Int
    public let maxEntries: Int
    private let lock = NSLock()
    private var entries: [Key: Raster] = [:]
    /// Most recently used last.
    private var order: [Key] = []
    private(set) public var bytes = 0

    public init(maxBytes: Int = 160 * 1024 * 1024, maxEntries: Int = 8) {
        self.maxBytes = maxBytes
        self.maxEntries = max(1, maxEntries)
    }

    public var count: Int { lock.withLock { entries.count } }

    public func raster(for key: Key) -> Raster? {
        lock.withLock {
            guard let raster = entries[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return raster
        }
    }

    /// Stores the raster unless it alone is over the byte limit.
    public func store(_ raster: Raster, for key: Key) {
        lock.withLock {
            guard raster.byteCount <= maxBytes else { return }
            if let existing = entries[key] {
                bytes -= existing.byteCount
                order.removeAll { $0 == key }
            }
            entries[key] = raster
            bytes += raster.byteCount
            order.append(key)
            while (bytes > maxBytes || entries.count > maxEntries), let oldest = order.first {
                order.removeFirst()
                if let evicted = entries.removeValue(forKey: oldest) { bytes -= evicted.byteCount }
            }
        }
    }

    /// The cached raster, or a fresh one from `make`, stored.
    public func render(_ key: Key, make: () -> Raster) -> Raster {
        if let cached = raster(for: key) { return cached }
        let raster = make()
        store(raster, for: key)
        return raster
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
            bytes = 0
        }
    }
}
