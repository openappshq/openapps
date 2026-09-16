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

    public init(display: DisplayID, wallpaper: Wallpaper, url: URL, format: AppliedFormat) {
        self.display = display
        self.wallpaper = wallpaper
        self.url = url
        self.format = format
    }
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

        public init(applied: [AppliedImage], failures: [(DisplayID, String)]) {
            self.applied = applied
            self.failures = failures
        }

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

    /// A display's file, rendered and written but not yet on the desktop:
    /// `commit` puts it there, `discard` removes it again. A dynamic file
    /// (a HEIC pair or time-of-day set) may be refused by the display at the
    /// commit; `prepareFallback` then makes the still for it.
    public struct PreparedImage: Equatable, Sendable {
        public let display: DisplayInfo
        public let wallpaper: Wallpaper
        public let url: URL
        public let format: AppliedFormat

        public var displayID: DisplayID { display.id }
        /// A HEIC the display may refuse.
        public var isDynamic: Bool { format == .appearancePair || format == .timeOfDay }
    }

    /// What `prepare` made of a plan: the files it could write, and the
    /// displays it could not render or write for.
    public struct Prepared: Sendable {
        public var images: [PreparedImage]
        public var failures: [(DisplayID, String)]
    }

    /// The display refused the dynamic file at the commit: the caller
    /// prepares and commits the fallback still, or discards.
    public struct DynamicRefused: Error, Sendable {
        public let image: PreparedImage
        public let underlying: String
    }

    /// Applies each display's document: `prepare`, then `commit` for each
    /// file, with the fallback still where a display refuses the HEIC. A
    /// still is a PNG of the light side; a light/dark document is a HEIC
    /// appearance pair and a time-of-day document a HEIC with its frames —
    /// and where the display refuses the HEIC, a PNG of the side (or the
    /// moment) that fits now, marked so the app swaps it on theme change.
    /// `side` forces one side as a PNG (the swap itself). Displays with the
    /// same document and context share a render through the cache. The app
    /// runs the halves apart, so that what reaches the desktop can be
    /// decided per display, and per fallback, at the moment of the commit.
    public func apply(_ plan: [DisplayInfo: Wallpaper], side forcedSide: Side? = nil, now: Date = Date()) throws -> [AppliedImage] {
        let prepared = try prepare(plan, side: forcedSide, now: now)
        var applied: [AppliedImage] = []
        var failures = prepared.failures
        for image in prepared.images {
            do {
                applied.append(try commit(image))
            } catch let refused as DynamicRefused {
                do {
                    applied.append(try commit(try prepareFallback(for: refused.image, now: now)))
                } catch {
                    failures.append((image.displayID, error.localizedDescription))
                }
            } catch {
                failures.append((image.displayID, error.localizedDescription))
            }
        }
        if !failures.isEmpty { throw Failure(applied: applied, failures: failures) }
        return applied
    }

    /// Renders and writes each display's file, touching no desktop. The
    /// files are recorded in the manifest, so an uncommitted one is owned
    /// like any other and pruned in time; `discard` removes it at once.
    public func prepare(_ plan: [DisplayInfo: Wallpaper], side forcedSide: Side? = nil, now: Date = Date()) throws -> Prepared {
        var prepared = Prepared(images: [], failures: [])
        try prepareDirectory()
        var manifest = AppliedManifest.load(in: directory)
        for (display, wallpaper) in plan.sorted(by: { $0.key.id < $1.key.id }) {
            do {
                let context = display.renderContext
                let image: PreparedImage
                switch (wallpaper.pair, forcedSide) {
                case (.still, _), (_, .some):
                    let side = forcedSide ?? .light
                    let url = try writeStill(wallpaper, side: side, context: context, display: display.id, manifest: &manifest)
                    image = PreparedImage(display: display, wallpaper: wallpaper, url: url, format: forcedSide == nil ? .still : .fallbackStill)
                case (.lightDark, nil):
                    let light = render(wallpaper, side: .light, context: context)
                    let dark = render(wallpaper, side: .dark, context: context)
                    let heic = try DynamicDesktop.appearancePair(light: light, dark: dark)
                    let url = try write(heic, for: display.id, extension: "heic", manifest: &manifest)
                    image = PreparedImage(display: display, wallpaper: wallpaper, url: url, format: .appearancePair)
                case (.timeOfDay(let frames), nil):
                    // Streamed: one frame rendered per encoder call, never
                    // the whole set in memory.
                    let count = max(2, frames)
                    let heic = try DynamicDesktop.timeOfDay(frameCount: count) { renderer.renderFrame(wallpaper, index: $0, of: count, context: context) }
                    let url = try write(heic, for: display.id, extension: "heic", manifest: &manifest)
                    image = PreparedImage(display: display, wallpaper: wallpaper, url: url, format: .timeOfDay)
                }
                prepared.images.append(image)
            } catch {
                prepared.failures.append((display.id, error.localizedDescription))
            }
        }
        manifest.save(in: directory)
        return prepared
    }

    /// The still a display that refused the dynamic file gets instead: the
    /// light side of a pair, or the moment of a time-of-day set that fits
    /// now, marked as a fallback so the app swaps it on theme change. No
    /// desktop is touched.
    public func prepareFallback(for image: PreparedImage, now: Date = Date()) throws -> PreparedImage {
        try prepareDirectory()
        var manifest = AppliedManifest.load(in: directory)
        let context = image.display.renderContext
        let url: URL
        switch image.format {
        case .timeOfDay:
            let moment = renderer.renderMoment(image.wallpaper, dayFraction: DayClock.fraction(of: now), context: context)
            guard let png = moment.pngData() else { throw ApplyError.encoding }
            url = try write(png, for: image.displayID, extension: "png", manifest: &manifest)
        case .appearancePair, .still, .fallbackStill:
            url = try writeStill(image.wallpaper, side: .light, context: context, display: image.displayID, manifest: &manifest)
        }
        manifest.save(in: directory)
        return PreparedImage(display: image.display, wallpaper: image.wallpaper, url: url, format: .fallbackStill)
    }

    /// Hands one prepared file to the desktop applier, then prunes that
    /// display's older files. The only place a desktop changes. A display
    /// that refuses a dynamic file throws `DynamicRefused` (the file stays
    /// until the caller discards it or commits its fallback).
    public func commit(_ image: PreparedImage) throws -> AppliedImage {
        do {
            try applier.apply(imageAt: image.url, to: image.displayID)
        } catch {
            if image.isDynamic { throw DynamicRefused(image: image, underlying: error.localizedDescription) }
            throw error
        }
        var manifest = AppliedManifest.load(in: directory)
        manifest.markCommitted(image.url.lastPathComponent, for: image.displayID)
        prune(display: image.displayID, manifest: &manifest)
        manifest.save(in: directory)
        return AppliedImage(display: image.displayID, wallpaper: image.wallpaper, url: image.url, format: image.format)
    }

    /// Removes a prepared file that will not be committed, and its
    /// manifest entry, so a refused apply leaves nothing behind and never
    /// pushes the file the desktop shows out of the kept window.
    public func discard(_ image: PreparedImage) {
        var manifest = AppliedManifest.load(in: directory)
        let name = image.url.lastPathComponent
        if let entry = manifest.entry(named: name, for: image.displayID) {
            manifest.remove(entry, for: image.displayID)
            manifest.save(in: directory)
        }
        let realDirectory = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.isOwnedRegularFile(image.url, inside: realDirectory) else { return }
        try? FileManager.default.removeItem(at: image.url)
    }

    /// Re-applies a file that was applied before (the pin): no render, the
    /// same URL handed over again — only while it is still one of the
    /// applier's own regular files, listed in its manifest for that display
    /// as committed (a prepared file never committed, or since discarded,
    /// is refused). The one desktop call that asks no license: it keeps
    /// what an allowed apply already put there, and makes nothing new.
    public func reapply(_ url: URL, to display: DisplayID) throws {
        let realDirectory = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().standardizedFileURL.path
        let manifest = AppliedManifest.load(in: directory)
        guard manifest.entry(named: url.lastPathComponent, for: display)?.committed == true,
              Self.isOwnedRegularFile(url, inside: realDirectory) else {
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
        /// The file reached a desktop through `commit`. A prepared file not
        /// yet committed, or discarded, is never one the pin may hand over.
        var committed = false

        init(name: String, counter: Int, committed: Bool = false) {
            self.name = name
            self.counter = counter
            self.committed = committed
        }

        enum CodingKeys: String, CodingKey { case name, counter, committed }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            counter = try container.decode(Int.self, forKey: .counter)
            committed = try container.decodeIfPresent(Bool.self, forKey: .committed) ?? false
        }
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

    /// The file reached the desktop: the pin may hand it over again.
    mutating func markCommitted(_ name: String, for display: DisplayID) {
        guard let index = files[String(display)]?.firstIndex(where: { $0.name == name }) else { return }
        files[String(display)]?[index].committed = true
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

    func entry(named name: String, for display: DisplayID) -> Entry? {
        files[String(display)]?.first { $0.name == name }
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

/// What a shuffle applies: a curated document (Shuffle.next), or one of
/// the favorites, for every display at once or one per display. Every
/// pick avoids the display's current document when there is any other
/// choice. `template` is the document whose pins a random pick keeps
/// (the draft); a random pick also keeps the pins of the display's own
/// document when the draft has none. A display for which the curated
/// draw finds nothing better is left out of the plan: it keeps what it
/// shows. `renderer` (the app's, with its imports) and `context` per
/// display serve the gate; one curated draw per display, no retries
/// around it.
public enum ShufflePlanner {
    public static func plan(
        displays: [DisplayInfo], current: [DisplayID: Wallpaper], favorites: [Wallpaper], favoritesOnly: Bool,
        sameOnAllDisplays: Bool, template: Wallpaper? = nil, renderer: WallpaperRenderer = WallpaperRenderer(),
        context: ((DisplayInfo) -> RenderContext)? = nil, using generator: inout SeededGenerator
    ) -> [DisplayInfo: Wallpaper] {
        var plan: [DisplayInfo: Wallpaper] = [:]
        guard !displays.isEmpty else { return plan }
        let pool = favoritesOnly && !favorites.isEmpty ? favorites : []
        let contextFor = context ?? { $0.renderContext }
        if sameOnAllDisplays {
            let avoid = Set(current.values)
            let first = displays.first { $0.isMain } ?? displays[0]
            if let pick = next(pool: pool, avoiding: avoid, template: template ?? current.values.first, renderer: renderer, context: contextFor(first), using: &generator) {
                for display in displays { plan[display] = pick }
            }
        } else {
            var taken: Set<Wallpaper> = []
            for display in displays.sorted(by: { $0.id < $1.id }) {
                var avoid = taken
                if let now = current[display.id] { avoid.insert(now) }
                guard let pick = next(pool: pool, avoiding: avoid, template: template ?? current[display.id], renderer: renderer, context: contextFor(display), using: &generator) else { continue }
                taken.insert(pick)
                plan[display] = pick
            }
        }
        return plan
    }

    /// From the pool when there is one (the favorites), else one curated
    /// draw — nil when it finds nothing better. A pool with nothing left
    /// to avoid falls back to any entry.
    static func next(pool: [Wallpaper], avoiding: Set<Wallpaper>, template: Wallpaper?, renderer: WallpaperRenderer, context: RenderContext, using generator: inout SeededGenerator) -> Wallpaper? {
        if !pool.isEmpty {
            let candidates = pool.filter { !avoiding.contains($0) }
            let source = candidates.isEmpty ? pool : candidates
            return source[Int(generator.next() % UInt64(source.count))]
        }
        // The gate's sameness veto already keeps the draw off the template;
        // a draw that still lands on a document to avoid is "nothing better".
        guard let candidate = Shuffle.next(from: template, using: &generator, renderer: renderer, context: context).document, !avoiding.contains(candidate) else { return nil }
        return candidate
    }
}
