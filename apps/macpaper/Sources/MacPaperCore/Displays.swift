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

    public init(id: DisplayID, name: String, pointSize: CGSize, scale: CGFloat, notchWidth: CGFloat? = nil, isMain: Bool = false) {
        self.id = id
        self.name = name
        self.pointSize = pointSize
        self.scale = scale
        self.notchWidth = notchWidth
        self.isMain = isMain
    }

    public var pixelSize: PixelSize { PixelSize(points: pointSize, scale: scale) }
    public var hasNotch: Bool { notchWidth != nil }
}

/// Sets a display's desktop picture. The app's applier calls
/// `NSWorkspace.shared.setDesktopImageURL`; tests and the preview harness
/// use a fake, so nothing but the running app can change a desktop.
public protocol DesktopApplier: Sendable {
    func apply(imageAt url: URL, to display: DisplayID) throws
}

/// Records every call, and can be told to fail.
public final class RecordingApplier: DesktopApplier, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let url: URL
        public let display: DisplayID
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    public var failure: (any Error)?

    public init() {}

    public var calls: [Call] { lock.withLock { recorded } }

    public func apply(imageAt url: URL, to display: DisplayID) throws {
        if let failure { throw failure }
        lock.withLock { recorded.append(Call(url: url, display: display)) }
    }
}

/// One apply of one document to one display: the file that was written and
/// handed to the applier.
public struct AppliedImage: Equatable, Sendable {
    public let display: DisplayID
    public let wallpaper: Wallpaper
    public let url: URL
}

/// Renders a document for each display and hands the files to the
/// `DesktopApplier`. macOS ignores a new image at the URL it already shows,
/// so every apply writes a new file, `<display>-<counter>.png`, and prunes
/// that display's older files down to `keptPerDisplay`. A failure on one
/// display is thrown after the others were tried, with what did succeed.
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

    /// Applies each display's document. Displays with the same document and
    /// pixel size share one render (and, through the cache, the same
    /// document applied again shares it too).
    public func apply(_ plan: [DisplayInfo: Wallpaper]) throws -> [AppliedImage] {
        var applied: [AppliedImage] = []
        var failures: [(DisplayID, String)] = []
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (display, wallpaper) in plan.sorted(by: { $0.key.id < $1.key.id }) {
            do {
                let raster = cache.render(RenderCache.Key(wallpaper: wallpaper, size: display.pixelSize)) {
                    renderer.render(wallpaper, size: display.pixelSize)
                }
                guard let png = raster.pngData() else { throw ApplyError.encoding }
                let url = nextURL(for: display.id)
                try png.write(to: url, options: .atomic)
                try applier.apply(imageAt: url, to: display.id)
                applied.append(AppliedImage(display: display.id, wallpaper: wallpaper, url: url))
                prune(display: display.id, keeping: url)
            } catch {
                failures.append((display.id, error.localizedDescription))
            }
        }
        if !failures.isEmpty { throw Failure(applied: applied, failures: failures) }
        return applied
    }

    enum ApplyError: Error, LocalizedError {
        case encoding

        var errorDescription: String? { "The wallpaper could not be encoded as PNG." }
    }

    /// `applied/<display>-<n>.png`, `n` one past the highest on disk.
    func nextURL(for display: DisplayID) -> URL {
        let existing = files(for: display)
        let next = (existing.map(\.counter).max() ?? 0) + 1
        return directory.appendingPathComponent("\(display)-\(next).png")
    }

    private struct AppliedFile {
        let url: URL
        let counter: Int
    }

    private func files(for display: DisplayID) -> [AppliedFile] {
        let prefix = "\(display)-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".png"),
                  let counter = Int(name.dropFirst(prefix.count).dropLast(4)) else { return nil }
            return AppliedFile(url: directory.appendingPathComponent(name), counter: counter)
        }
    }

    /// Keeps the newest `keptPerDisplay` files of the display, the current
    /// one included whatever its counter.
    private func prune(display: DisplayID, keeping current: URL) {
        let sorted = files(for: display).sorted { $0.counter > $1.counter }
        for file in sorted.dropFirst(keptPerDisplay) where file.url != current {
            try? FileManager.default.removeItem(at: file.url)
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
