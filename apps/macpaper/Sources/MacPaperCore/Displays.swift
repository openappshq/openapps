import CoreGraphics
import Foundation

/// A display's identity: `CGDirectDisplayID`, what `NSScreen` reports as
/// `NSScreenNumber`. Stable while the display is connected.
public typealias DisplayID = UInt32

/// What the core needs to know about a display: its size, in points and
/// pixels, and whether it has a notch and how wide.
public struct DisplayInfo: Hashable, Identifiable, Sendable {
    public let id: DisplayID
    public let name: String
    public let pointSize: CGSize
    public let scale: CGFloat
    /// The notch's width in points, nil without one.
    public let notchWidth: CGFloat?
    /// The main display: the one with the menu bar and the Dock.
    public let isMain: Bool
    /// The top safe-area inset in points: the notch's height, or the menu
    /// bar's on a display without one (0 when unknown).
    public let topInset: CGFloat

    public init(id: DisplayID, name: String, pointSize: CGSize, scale: CGFloat, notchWidth: CGFloat? = nil, isMain: Bool = false, topInset: CGFloat = 0) {
        self.id = id
        self.name = name
        self.pointSize = pointSize
        self.scale = scale
        self.notchWidth = notchWidth
        self.isMain = isMain
        self.topInset = topInset
    }

    public var pixelSize: PixelSize { PixelSize(points: pointSize, scale: scale) }
    public var hasNotch: Bool { notchWidth != nil }
}

/// Sets a display's desktop picture, and says which file it shows. The
/// app's applier calls `NSWorkspace.shared.setDesktopImageURL` and
/// `desktopImageURL(for:)`; tests and the preview harness use a fake, so
/// nothing but the running app can change a desktop.
public protocol DesktopApplier: Sendable {
    func apply(imageAt url: URL, to display: DisplayID) throws
    /// The file the display shows now, nil when unknown.
    func currentImageURL(for display: DisplayID) -> URL?
}

/// Records every call, can be told to fail, and can refuse HEIC files (a
/// display that only takes stills).
public final class RecordingApplier: DesktopApplier, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let url: URL
        public let display: DisplayID
    }

    public struct RefusedHEIC: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "This display takes no dynamic desktop." }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    public var failure: (any Error)?
    /// Displays whose every apply fails, for partial-failure tests.
    public var failingDisplays: Set<DisplayID> = []
    public var refusesHEIC = false
    /// Seconds each apply takes, so a test can catch an apply in flight.
    public var delay: TimeInterval = 0
    /// What `currentImageURL` answers: the last applied by default.
    public var currentOverride: [DisplayID: URL?] = [:]

    public init() {}

    public var calls: [Call] { lock.withLock { recorded } }

    public func apply(imageAt url: URL, to display: DisplayID) throws {
        if let failure { throw failure }
        if failingDisplays.contains(display) { throw failure ?? RefusedHEIC() }
        if refusesHEIC, url.pathExtension == "heic" { throw RefusedHEIC() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { recorded.append(Call(url: url, display: display)) }
    }

    public func currentImageURL(for display: DisplayID) -> URL? {
        if let override = currentOverride[display] { return override }
        return lock.withLock { recorded.last { $0.display == display }?.url }
    }
}

/// What kind of file an apply handed over.
public enum AppliedFormat: String, Codable, Hashable, Sendable {
    /// A PNG still.
    case still
    /// A HEIC with the light/dark appearance record.
    case appearancePair
    /// A HEIC with the time-of-day record.
    case timeOfDay
    /// The display refused the HEIC: a PNG of one side, swapped by the app
    /// on theme change while it runs.
    case fallbackStill
}

/// One apply of one document to one display: the file that was written and
/// handed to the applier.
public struct AppliedImage: Equatable, Sendable {
    public let display: DisplayID
    public let wallpaper: Wallpaper
    public let url: URL
    public let format: AppliedFormat
}

/// Renders a document for each display and hands the files to the
/// `DesktopApplier`. macOS ignores a new image at the URL it already shows,
/// so every apply writes a new file, `<display>-<counter>.png`, and prunes
/// that display's older files down to `keptPerDisplay`. A failure on one
/// display is thrown after the others were tried, with what did succeed.
///
/// Ownership: the applier only ever deletes what it wrote. `manifest.json`
/// in the directory lists the names it created per display; pruning walks
/// that list, and removes an entry only while it is still a regular file
/// (no symlink, no directory) whose real path sits directly inside the
/// directory's real path. Anything else with a matching name is left
/// alone. New names are written without overwriting: a foreign file under
/// the next name bumps the counter. A directory that is itself a symlink
/// is refused.
public struct WallpaperApplier: Sendable {
    public struct Failure: Error, LocalizedError, Sendable {
        public let applied: [AppliedImage]
        public let failures: [(DisplayID, String)]

        public var errorDescription: String? {
            failures.map { "Display \($0.0): \($0.1)" }.joined(separator: "\n")
        }
    }

    public let applier: any DesktopApplier
    public let renderer: WallpaperRenderer
    public let cache: RenderCache
    public let directory: URL
    public let keptPerDisplay: Int

    public init(applier: any DesktopApplier, renderer: WallpaperRenderer, cache: RenderCache, directory: URL, keptPerDisplay: Int = 3) {
        self.applier = applier
        self.renderer = renderer
        self.cache = cache
        self.directory = directory
        self.keptPerDisplay = max(1, keptPerDisplay)
    }

    /// Applies each display's document. A still is a PNG of the light side;
    /// a light/dark document is a HEIC appearance pair and a time-of-day
    /// document a HEIC with its frames — and where the display refuses the
    /// HEIC, a PNG of the side (or the moment) that fits now, marked so the
    /// app swaps it on theme change. `side` forces one side as a PNG (the
    /// swap itself). Displays with the same document and context share a
    /// render through the cache.
    public func apply(_ plan: [DisplayInfo: Wallpaper], side forcedSide: Side? = nil, now: Date = Date()) throws -> [AppliedImage] {
        var applied: [AppliedImage] = []
        var failures: [(DisplayID, String)] = []
        try prepareDirectory()
        var manifest = AppliedManifest.load(in: directory)
        for (display, wallpaper) in plan.sorted(by: { $0.key.id < $1.key.id }) {
            do {
                let context = display.renderContext
                let image: AppliedImage
                switch (wallpaper.pair, forcedSide) {
                case (.still, _), (_, .some):
                    let side = forcedSide ?? .light
                    let url = try writeStill(wallpaper, side: side, context: context, display: display.id, manifest: &manifest)
                    try applier.apply(imageAt: url, to: display.id)
                    image = AppliedImage(display: display.id, wallpaper: wallpaper, url: url, format: forcedSide == nil ? .still : .fallbackStill)
                case (.lightDark, nil):
                    let light = render(wallpaper, side: .light, context: context)
                    let dark = render(wallpaper, side: .dark, context: context)
                    let heic = try DynamicDesktop.appearancePair(light: light, dark: dark)
                    image = try applyDynamic(heic, format: .appearancePair, wallpaper: wallpaper, display: display, manifest: &manifest) { manifest in
                        try writeStill(wallpaper, side: .light, context: context, display: display.id, manifest: &manifest)
                    }
                case (.timeOfDay(let frames), nil):
                    // Streamed: one frame rendered per encoder call, never
                    // the whole set in memory.
                    let count = max(2, frames)
                    let heic = try DynamicDesktop.timeOfDay(frameCount: count) { renderer.renderFrame(wallpaper, index: $0, of: count, context: context) }
                    image = try applyDynamic(heic, format: .timeOfDay, wallpaper: wallpaper, display: display, manifest: &manifest) { manifest in
                        let moment = renderer.renderMoment(wallpaper, dayFraction: DayClock.fraction(of: now), context: context)
                        guard let png = moment.pngData() else { throw ApplyError.encoding }
                        return try write(png, for: display.id, extension: "png", manifest: &manifest)
                    }
                }
                applied.append(image)
                prune(display: display.id, manifest: &manifest)
            } catch {
                failures.append((display.id, error.localizedDescription))
            }
        }
        manifest.save(in: directory)
        if !failures.isEmpty { throw Failure(applied: applied, failures: failures) }
        return applied
    }

    /// Re-applies a file that was applied before (the pin): no render, the
    /// same URL handed over again — only while it is still one of the
    /// applier's own regular files, listed in its manifest for that display.
    public func reapply(_ url: URL, to display: DisplayID) throws {
        let realDirectory = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().standardizedFileURL.path
        let manifest = AppliedManifest.load(in: directory)
        guard manifest.names(for: display).contains(url.lastPathComponent), Self.isOwnedRegularFile(url, inside: realDirectory) else {
            throw ApplyError.notOwned
        }
        try applier.apply(imageAt: url, to: display)
    }

    private func render(_ wallpaper: Wallpaper, side: Side, context: RenderContext) -> Raster {
        let key = RenderCache.Key(wallpaper: wallpaper, side: side, context: context)
        return cache.render(key) { renderer.render(wallpaper, side: side, context: context) }
    }

    private func writeStill(_ wallpaper: Wallpaper, side: Side, context: RenderContext, display: DisplayID, manifest: inout AppliedManifest) throws -> URL {
        let raster = render(wallpaper, side: side, context: context)
        guard let png = raster.pngData() else { throw ApplyError.encoding }
        return try write(png, for: display, extension: "png", manifest: &manifest)
    }

    /// Hands a HEIC over; when the display refuses it, writes and applies
    /// the still `fallback` makes and marks the image as a fallback.
    private func applyDynamic(_ heic: Data, format: AppliedFormat, wallpaper: Wallpaper, display: DisplayInfo, manifest: inout AppliedManifest, fallback: (inout AppliedManifest) throws -> URL) throws -> AppliedImage {
        let url = try write(heic, for: display.id, extension: "heic", manifest: &manifest)
        do {
            try applier.apply(imageAt: url, to: display.id)
            return AppliedImage(display: display.id, wallpaper: wallpaper, url: url, format: format)
        } catch {
            let still = try fallback(&manifest)
            try applier.apply(imageAt: still, to: display.id)
            return AppliedImage(display: display.id, wallpaper: wallpaper, url: still, format: .fallbackStill)
        }
    }

    public enum ApplyError: Error, LocalizedError, Equatable {
        case encoding
        case directoryIsSymlink
        case noFreeName
        case notOwned

        public var errorDescription: String? {
            switch self {
            case .encoding: "The wallpaper could not be encoded as PNG."
            case .directoryIsSymlink: "The applied folder is a symbolic link; refusing to write through it."
            case .noFreeName: "No free file name in the applied folder."
            case .notOwned: "The recorded file is not one macPaper wrote; not re-applied."
            }
        }
    }

    /// Creates the directory; refuses one that is a symbolic link.
    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ApplyError.directoryIsSymlink
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `<display>-<n>.<ext>`, `n` one past the manifest's highest, skipping
    /// any name something else already holds; written without overwriting.
    private func write(_ data: Data, for display: DisplayID, extension ext: String, manifest: inout AppliedManifest) throws -> URL {
        var counter = manifest.highestCounter(for: display) + 1
        for _ in 0..<1000 {
            let name = "\(display)-\(counter).\(ext)"
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                manifest.record(name, counter: counter, for: display)
                return url
            } catch CocoaError.fileWriteFileExists {
                counter += 1
            }
        }
        throw ApplyError.noFreeName
    }

    /// Removes the display's oldest manifest entries beyond `keptPerDisplay`,
    /// each only while it is still a regular file directly inside the
    /// directory. Entries leave the manifest either way.
    private func prune(display: DisplayID, manifest: inout AppliedManifest) {
        let stale = manifest.entriesBeyond(keptPerDisplay, for: display)
        guard !stale.isEmpty else { return }
        let realDirectory = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().standardizedFileURL.path
        for entry in stale {
            manifest.remove(entry, for: display)
            guard entry.name.firstIndex(of: "/") == nil, !entry.name.hasPrefix(".") else { continue }
            let url = directory.appendingPathComponent(entry.name)
            guard Self.isOwnedRegularFile(url, inside: realDirectory) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A regular file (not a symlink, not a directory) whose real parent is
    /// exactly `realDirectory`.
    static func isOwnedRegularFile(_ url: URL, inside realDirectory: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        let real = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().standardizedFileURL
        return real.deletingLastPathComponent().path == realDirectory
    }
}

/// The names the applier wrote, per display, oldest first: `manifest.json`
/// in the applied directory. Only what is listed here is ever deleted.
struct AppliedManifest: Codable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        let name: String
        let counter: Int
    }

    static let fileName = "manifest.json"
    var version = 1
    var files: [String: [Entry]] = [:]

    static func load(in directory: URL) -> AppliedManifest {
        (try? JSONFile<AppliedManifest>(url: directory.appendingPathComponent(fileName)).load()) ?? AppliedManifest()
    }

    func save(in directory: URL) {
        try? JSONFile<AppliedManifest>(url: directory.appendingPathComponent(Self.fileName)).save(self)
    }

    func highestCounter(for display: DisplayID) -> Int {
        files[String(display)]?.map(\.counter).max() ?? 0
    }

    mutating func record(_ name: String, counter: Int, for display: DisplayID) {
        files[String(display), default: []].append(Entry(name: name, counter: counter))
    }

    /// The oldest entries past the newest `kept`.
    func entriesBeyond(_ kept: Int, for display: DisplayID) -> [Entry] {
        let entries = files[String(display)] ?? []
        guard entries.count > kept else { return [] }
        return Array(entries.prefix(entries.count - kept))
    }

    mutating func remove(_ entry: Entry, for display: DisplayID) {
        files[String(display)]?.removeAll { $0 == entry }
    }

    /// Every name the manifest holds for a display, newest last.
    func names(for display: DisplayID) -> [String] {
        (files[String(display)] ?? []).map(\.name)
    }
}

// MARK: - Pin so it stays

/// Which displays show something other than the file recorded for them,
/// and are not excluded (a display applied "this Space only"). Pure: the
/// app asks on launch, wake, unlock, Space and display changes and
/// re-applies exactly these.
public enum PinPolicy {
    public static func displaysToReapply(recorded: [DisplayID: URL], current: (DisplayID) -> URL?, excluded: Set<DisplayID>, connected: Set<DisplayID>) -> [DisplayID] {
        recorded.keys.sorted().filter { display in
            guard connected.contains(display), !excluded.contains(display), let file = recorded[display] else { return false }
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            guard let shown = current(display) else { return true }
            return shown.standardizedFileURL.path != file.standardizedFileURL.path
        }
    }
}

// MARK: - Which document goes where

/// Turns "apply this" into a per-display plan. With "same on all displays"
/// every display gets the document; otherwise the chosen display alone, or
/// all of them on request.
public enum ApplyScope: Sendable, Equatable {
    case display(DisplayID)
    case allDisplays

    public static func plan(_ wallpaper: Wallpaper, scope: ApplyScope, displays: [DisplayInfo], sameOnAllDisplays: Bool) -> [DisplayInfo: Wallpaper] {
        var plan: [DisplayInfo: Wallpaper] = [:]
        switch (scope, sameOnAllDisplays) {
        case (.allDisplays, _), (_, true):
            for display in displays { plan[display] = wallpaper }
        case (.display(let id), false):
            if let display = displays.first(where: { $0.id == id }) { plan[display] = wallpaper }
        }
        return plan
    }
}

// MARK: - Shuffle

public enum ShuffleInterval: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case minutes15, minutes30
    case hour1, hours3, hours6
    case day1

    public var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .minutes15: 15 * 60
        case .minutes30: 30 * 60
        case .hour1: 3600
        case .hours3: 3 * 3600
        case .hours6: 6 * 3600
        case .day1: 24 * 3600
        }
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .minutes15: "Every 15 minutes"
        case .minutes30: "Every 30 minutes"
        case .hour1: "Every hour"
        case .hours3: "Every 3 hours"
        case .hours6: "Every 6 hours"
        case .day1: "Every day"
        }
    }
}

/// When the next shuffle is due: `interval` after the last apply (or the
/// moment shuffle was turned on, when nothing was applied yet). Missed
/// shuffles while the Mac slept are not caught up: one is due, not several.
public struct ShuffleSchedule: Hashable, Sendable {
    public var interval: ShuffleInterval
    public var anchor: Date?

    public init(interval: ShuffleInterval, anchor: Date?) {
        self.interval = interval
        self.anchor = anchor
    }

    public func nextDue(now: Date) -> Date? {
        guard let seconds = interval.seconds else { return nil }
        guard let anchor else { return now.addingTimeInterval(seconds) }
        return anchor.addingTimeInterval(seconds)
    }

    public func isDue(now: Date) -> Bool {
        guard let next = nextDue(now: now) else { return false }
        return next <= now
    }
}

/// What a shuffle applies: a random document, or one of the favorites, for
/// every display at once or one per display. Every pick avoids the display's
/// current document when there is any other choice.
public enum ShufflePlanner {
    public static func plan(
        displays: [DisplayInfo], current: [DisplayID: Wallpaper], favorites: [Wallpaper], favoritesOnly: Bool,
        sameOnAllDisplays: Bool, using generator: inout SeededGenerator
    ) -> [DisplayInfo: Wallpaper] {
        var plan: [DisplayInfo: Wallpaper] = [:]
        guard !displays.isEmpty else { return plan }
        let pool = favoritesOnly && !favorites.isEmpty ? favorites : []
        if sameOnAllDisplays {
            let avoid = Set(current.values)
            let pick = next(pool: pool, avoiding: avoid, using: &generator)
            for display in displays { plan[display] = pick }
        } else {
            var taken: Set<Wallpaper> = []
            for display in displays.sorted(by: { $0.id < $1.id }) {
                var avoid = taken
                if let now = current[display.id] { avoid.insert(now) }
                let pick = next(pool: pool, avoiding: avoid, using: &generator)
                taken.insert(pick)
                plan[display] = pick
            }
        }
        return plan
    }

    /// From the pool when there is one (the favorites), else a random
    /// document. A pool with nothing left to avoid falls back to any entry.
    static func next(pool: [Wallpaper], avoiding: Set<Wallpaper>, using generator: inout SeededGenerator) -> Wallpaper {
        if !pool.isEmpty {
            let candidates = pool.filter { !avoiding.contains($0) }
            let source = candidates.isEmpty ? pool : candidates
            return source[Int(generator.next() % UInt64(source.count))]
        }
        var candidate = Wallpaper.random(using: &generator)
        var attempts = 0
        while avoiding.contains(candidate), attempts < 8 {
            candidate = Wallpaper.random(using: &generator)
            attempts += 1
        }
        return candidate
    }
}
