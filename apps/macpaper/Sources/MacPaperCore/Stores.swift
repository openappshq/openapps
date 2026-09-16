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
    public var blocklist: URL { root.appendingPathComponent("never.json") }
    public var history: URL { root.appendingPathComponent("history.json") }
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

/// An array whose undecodable elements are dropped instead of failing the
/// whole file: one hand-edited or newer favorite does not hide the rest.
struct LossyArray<Element: Codable & Sendable>: Codable, Sendable {
    var elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.elements = elements
    }

    func encode(to encoder: any Encoder) throws {
        try elements.encode(to: encoder)
    }

    private struct Skip: Codable {}
}

// MARK: - Favorites

public struct Favorite: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var wallpaper: Wallpaper
    public let addedAt: Date
    /// What the user called it; nil is titled from the palette and the
    /// generator (`title`). Files from before names decode without one.
    public var name: String?

    public init(id: UUID = UUID(), wallpaper: Wallpaper, addedAt: Date = Date(), name: String? = nil) {
        self.id = id
        self.wallpaper = wallpaper
        self.addedAt = addedAt
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The name, or "Sunset · Mesh".
    public var title: String { name ?? Self.defaultTitle(for: wallpaper) }

    /// "Sunset · Mesh": the palette and the generator.
    public static func defaultTitle(for wallpaper: Wallpaper) -> String {
        "\(PresetPalettes.name(for: wallpaper.generator.colors)) · \(wallpaper.generator.kind.title)"
    }

    /// "Mesh · seed 42": under the title.
    public var subtitle: String {
        var parts = ["\(wallpaper.generator.kind.title)", "seed \(wallpaper.seedText)"]
        if !wallpaper.pair.isStill { parts.append(wallpaper.pair.title) }
        return parts.joined(separator: " · ")
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
        var favorites: LossyArray<Favorite>
    }

    private let file: JSONFile<File>
    private let lock = NSLock()
    private var favorites: [Favorite]

    public init(fileURL: URL) {
        file = JSONFile(url: fileURL)
        favorites = (try? file.load())?.favorites.elements ?? []
    }

    public var all: [Favorite] {
        lock.withLock { favorites }
    }

    public func contains(_ wallpaper: Wallpaper) -> Bool {
        lock.withLock { favorites.contains { $0.wallpaper == wallpaper } }
    }

    /// Adds the document unless it is one already (a name given then
    /// renames the existing one); returns the favorite.
    @discardableResult
    public func add(_ wallpaper: Wallpaper, at date: Date = Date(), name: String? = nil) throws -> Favorite {
        let name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return try lock.withLock {
            var next = favorites
            if let index = next.firstIndex(where: { $0.wallpaper == wallpaper }) {
                guard let name, next[index].name != name else { return next[index] }
                next[index].name = name
                try file.save(File(favorites: LossyArray(next)))
                favorites = next
                return next[index]
            }
            let favorite = Favorite(wallpaper: wallpaper, addedAt: date, name: name)
            next.insert(favorite, at: 0)
            try file.save(File(favorites: LossyArray(next)))
            favorites = next
            return favorite
        }
    }

    /// Renames a favorite; an empty name goes back to the derived title.
    public func rename(_ favorite: Favorite, to name: String?) throws {
        try lock.withLock {
            guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
            var next = favorites
            next[index] = Favorite(id: favorite.id, wallpaper: favorite.wallpaper, addedAt: favorite.addedAt, name: name)
            try file.save(File(favorites: LossyArray(next)))
            favorites = next
        }
    }

    public func remove(_ wallpaper: Wallpaper) throws {
        try lock.withLock {
            let next = favorites.filter { $0.wallpaper != wallpaper }
            guard next.count != favorites.count else { return }
            try file.save(File(favorites: LossyArray(next)))
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

// MARK: - History

/// One document that reached a desktop, and when.
public struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var wallpaper: Wallpaper
    public var appliedAt: Date

    public init(id: UUID = UUID(), wallpaper: Wallpaper, appliedAt: Date = Date()) {
        self.id = id
        self.wallpaper = wallpaper
        self.appliedAt = appliedAt
    }
}

/// What was applied, newest first, in `history.json`, bounded. Live apply
/// lands a document after every change, so an entry is *one look*: a
/// document with the same generator and seed as the newest entry replaces
/// it (a slider moved), anything else is a new entry (a shuffle, a
/// favorite, a new seed).
public final class HistoryStore: @unchecked Sendable {
    private struct File: Codable, Sendable {
        var version = 1
        var entries: LossyArray<HistoryEntry>
    }

    public let limit: Int
    private let file: JSONFile<File>
    private let lock = NSLock()
    private var entries: [HistoryEntry]

    public init(fileURL: URL, limit: Int = 40) {
        self.limit = max(1, limit)
        file = JSONFile(url: fileURL)
        entries = Array(((try? file.load())?.entries.elements ?? []).prefix(self.limit))
    }

    public var all: [HistoryEntry] {
        lock.withLock { entries }
    }

    public func record(_ wallpaper: Wallpaper, at date: Date = Date()) throws {
        try lock.withLock {
            var next = entries
            if let first = next.first, first.wallpaper.seed == wallpaper.seed, first.wallpaper.generator.kind == wallpaper.generator.kind {
                if first.wallpaper == wallpaper { return }
                next[0] = HistoryEntry(id: first.id, wallpaper: wallpaper, appliedAt: date)
            } else {
                next.removeAll { $0.wallpaper == wallpaper }
                next.insert(HistoryEntry(wallpaper: wallpaper, appliedAt: date), at: 0)
            }
            next = Array(next.prefix(limit))
            try file.save(File(entries: LossyArray(next)))
            entries = next
        }
    }

    public func remove(_ entry: HistoryEntry) throws {
        try lock.withLock {
            let next = entries.filter { $0.id != entry.id }
            guard next.count != entries.count else { return }
            try file.save(File(entries: LossyArray(next)))
            entries = next
        }
    }

    public func removeAll() throws {
        try lock.withLock {
            try file.save(File(entries: LossyArray([])))
            entries = []
        }
    }
}

// MARK: - Applied documents

/// Which document each display shows, by display id, in `applied.json`,
/// so the panel opens on the current wallpaper after a relaunch, plus the
/// file handed to macOS for it (the pin re-applies it), which displays
/// were applied "this Space only" (the pin leaves them alone) and which
/// got a fallback still (the app swaps it on theme change). The
/// `lastApplied` date drives the shuffle schedule.
public struct AppliedState: Codable, Hashable, Sendable {
    public var byDisplay: [String: Wallpaper]
    public var lastApplied: Date?
    /// The document the panel edits, applied or not.
    public var draft: Wallpaper?
    /// The applied file's path per display.
    public var fileByDisplay: [String: String]
    /// Displays applied "this Space only": off the pin until the next
    /// every-Space apply.
    public var perSpaceDisplays: Set<String>
    /// Displays showing a fallback still of a pair.
    public var fallbackDisplays: Set<String>

    public init(byDisplay: [String: Wallpaper] = [:], lastApplied: Date? = nil, draft: Wallpaper? = nil, fileByDisplay: [String: String] = [:], perSpaceDisplays: Set<String> = [], fallbackDisplays: Set<String> = []) {
        self.byDisplay = byDisplay
        self.lastApplied = lastApplied
        self.draft = draft
        self.fileByDisplay = fileByDisplay
        self.perSpaceDisplays = perSpaceDisplays
        self.fallbackDisplays = fallbackDisplays
    }

    private enum CodingKeys: String, CodingKey { case byDisplay, lastApplied, draft, fileByDisplay, perSpaceDisplays, fallbackDisplays }

    /// A document that no longer decodes (hand-edited, or from a newer
    /// version) is dropped on its own; the rest of the state stays.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawByDisplay = (try? container.decodeIfPresent([String: LossyDocument].self, forKey: .byDisplay)) ?? [:]
        byDisplay = rawByDisplay.compactMapValues(\.wallpaper)
        lastApplied = try container.decodeIfPresent(Date.self, forKey: .lastApplied)
        draft = (try? container.decodeIfPresent(LossyDocument.self, forKey: .draft))??.wallpaper
        fileByDisplay = try container.decodeIfPresent([String: String].self, forKey: .fileByDisplay) ?? [:]
        perSpaceDisplays = try container.decodeIfPresent(Set<String>.self, forKey: .perSpaceDisplays) ?? []
        fallbackDisplays = try container.decodeIfPresent(Set<String>.self, forKey: .fallbackDisplays) ?? []
    }

    public func wallpaper(for display: DisplayID) -> Wallpaper? {
        byDisplay[String(display)]
    }

    public func file(for display: DisplayID) -> URL? {
        fileByDisplay[String(display)].map { URL(fileURLWithPath: $0) }
    }

    public mutating func set(_ wallpaper: Wallpaper, for display: DisplayID) {
        byDisplay[String(display)] = wallpaper
    }

    /// Records an apply: the document, the file, the pin exclusion and the
    /// fallback mark for the display.
    public mutating func record(_ image: AppliedImage, perSpace: Bool) {
        let key = String(image.display)
        byDisplay[key] = image.wallpaper
        fileByDisplay[key] = image.url.path
        if perSpace { perSpaceDisplays.insert(key) } else { perSpaceDisplays.remove(key) }
        if image.format == .fallbackStill { fallbackDisplays.insert(key) } else { fallbackDisplays.remove(key) }
    }

    /// The recorded files by display id, for the pin.
    public var recordedFiles: [DisplayID: URL] {
        var out: [DisplayID: URL] = [:]
        for (key, path) in fileByDisplay { if let id = DisplayID(key) { out[id] = URL(fileURLWithPath: path) } }
        return out
    }

    public var perSpaceDisplayIDs: Set<DisplayID> { Set(perSpaceDisplays.compactMap(DisplayID.init)) }
    public var fallbackDisplayIDs: Set<DisplayID> { Set(fallbackDisplays.compactMap(DisplayID.init)) }
}

/// A document slot that decodes to nil instead of failing.
struct LossyDocument: Codable, Sendable {
    let wallpaper: Wallpaper?

    init(from decoder: any Decoder) throws {
        wallpaper = try? Wallpaper(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try wallpaper?.encode(to: encoder)
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
        public let side: Side
        public let context: RenderContext

        public init(wallpaper: Wallpaper, side: Side = .light, context: RenderContext) {
            self.wallpaper = wallpaper
            self.side = side
            self.context = context
        }

        public init(wallpaper: Wallpaper, size: PixelSize) {
            self.init(wallpaper: wallpaper, context: RenderContext(size: size))
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
