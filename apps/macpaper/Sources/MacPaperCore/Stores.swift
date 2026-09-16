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

/// Imported images for Pixelize and Dither, decoded through ImageIO's
/// bounded path (the longer edge at most `Raster.importMaxPixelSize`) and
/// kept in `imports/` as PNG under their content hash, so a favorite keeps
/// working after the original moves and no import is larger than a 6K
/// display. Decoded rasters are cached by reference within a byte limit,
/// least recently used first.
///
/// A reference is only ever resolved to a regular file directly inside the
/// directory (no path components, no symlink), and the decoded raster must
/// hash to the reference's content hash; anything else is "no image".
public final class ImportStore: ImageSource, @unchecked Sendable {
    public let directory: URL
    public let maxCacheBytes: Int
    private let lock = NSLock()
    private var cache: [ImageReference: Raster] = [:]
    /// Most recently used last.
    private var order: [ImageReference] = []
    private var bytes = 0

    public init(directory: URL, maxCacheBytes: Int = 96 * 1024 * 1024) {
        self.directory = directory
        self.maxCacheBytes = maxCacheBytes
    }

    public var cachedBytes: Int { lock.withLock { bytes } }
    public var cachedCount: Int { lock.withLock { cache.count } }

    /// Decodes the file (a PNG, JPEG, HEIC, TIFF… anything ImageIO reads),
    /// scaled down to the import bound, and stores it as PNG under its
    /// content hash. Throws when the image cannot be decoded; nothing is
    /// written then. Safe to call off the main actor.
    public func importImage(at url: URL, maxPixelSize: Int = Raster.importMaxPixelSize) throws -> ImageReference {
        guard let raster = Raster.decode(at: url, maxPixelSize: maxPixelSize) else { throw ImportError.undecodable }
        return try store(raster)
    }

    public func importImage(data: Data, maxPixelSize: Int = Raster.importMaxPixelSize) throws -> ImageReference {
        guard let raster = Raster.decode(data, maxPixelSize: maxPixelSize) else { throw ImportError.undecodable }
        return try store(raster)
    }

    private func store(_ raster: Raster) throws -> ImageReference {
        let hash = raster.contentHash
        let fileName = "\(hash.prefix(24)).png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let png = raster.pngData() else { throw ImportError.undecodable }
            try png.write(to: destination, options: .atomic)
        }
        let reference = ImageReference(fileName: fileName, contentHash: hash)
        remember(raster, for: reference)
        return reference
    }

    public func raster(for reference: ImageReference) -> Raster? {
        if let cached = lock.withLock({ () -> Raster? in
            guard let raster = cache[reference] else { return nil }
            order.removeAll { $0 == reference }
            order.append(reference)
            return raster
        }) { return cached }
        guard let url = containedFile(named: reference.fileName),
              let raster = Raster.decode(at: url, maxPixelSize: Raster.importMaxPixelSize),
              raster.contentHash == reference.contentHash else { return nil }
        remember(raster, for: reference)
        return raster
    }

    /// Whether the reference resolves to an image on disk; the panel says
    /// "Image missing" when it does not.
    public func hasImage(for reference: ImageReference) -> Bool {
        raster(for: reference) != nil
    }

    /// `directory/name` only while `name` is a single component and the
    /// entry is a regular file whose real parent is the directory itself.
    private func containedFile(named name: String) -> URL? {
        guard ImageReference.isValidFileName(name) else { return nil }
        let url = directory.appendingPathComponent(name)
        let realDirectory = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let real = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().standardizedFileURL
        guard real.deletingLastPathComponent().path == realDirectory else { return nil }
        return url
    }

    private func remember(_ raster: Raster, for reference: ImageReference) {
        lock.withLock {
            guard raster.byteCount <= maxCacheBytes else { return }
            if let existing = cache[reference] {
                bytes -= existing.byteCount
                order.removeAll { $0 == reference }
            }
            cache[reference] = raster
            bytes += raster.byteCount
            order.append(reference)
            while bytes > maxCacheBytes, let oldest = order.first {
                order.removeFirst()
                if let evicted = cache.removeValue(forKey: oldest) { bytes -= evicted.byteCount }
            }
        }
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
