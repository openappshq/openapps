import AppKit
import MacPaperCore
import ScreenSaver

/// The `macPaper.saver` module: shows the still the display has applied
/// and, with favorites saved, crossfades through them once a minute. Reads
/// the same documents the app keeps (`applied.json`, `favorites.json`,
/// `imports/`) through MacPaperCore and renders them at the screen's pixel
/// size; needs nothing from the app while it runs, and never writes.
/// The crossfade's bookkeeping, pure so it can be tested: which frame
/// shows, which is fading out, how far the fade is. Replacing the frames
/// resets everything, so a smaller set after a restart never indexes past
/// its end.
nonisolated public struct SaverPlayer: Equatable, Sendable {
    public private(set) var count = 0
    public private(set) var index = 0
    public private(set) var previousIndex: Int?
    /// 0…1 while crossfading, 1 when settled.
    public private(set) var blend = 1.0
    public private(set) var lastSwitch: Date
    public let holdSeconds: TimeInterval
    public let fadeSeconds: TimeInterval

    public init(now: Date = Date(), holdSeconds: TimeInterval = 60, fadeSeconds: TimeInterval = 1.5) {
        lastSwitch = now
        self.holdSeconds = holdSeconds
        self.fadeSeconds = fadeSeconds
    }

    /// A new set of frames: back to the first, settled.
    public mutating func replaceFrames(count: Int, now: Date) {
        self.count = max(0, count)
        index = 0
        previousIndex = nil
        blend = 1
        lastSwitch = now
    }

    /// One animation tick: advances a running fade, or starts the next
    /// frame's fade once the hold is over. Returns whether a redraw is due.
    public mutating func tick(now: Date, interval: TimeInterval) -> Bool {
        if blend < 1 {
            blend = min(1, blend + interval / fadeSeconds)
            if blend >= 1 { previousIndex = nil }
            return true
        }
        guard count > 1, now.timeIntervalSince(lastSwitch) >= holdSeconds else { return false }
        previousIndex = index
        index = (index + 1) % count
        blend = 0
        lastSwitch = now
        return true
    }

    /// The frame to draw, nil without frames; never past the end.
    public var currentIndex: Int? { count > 0 && index < count ? index : nil }
    public var fadingOutIndex: Int? { previousIndex.flatMap { $0 < count && blend < 1 ? $0 : nil } }
}

@objc(MacPaperSaverView)
public final class MacPaperSaverView: ScreenSaverView {
    private var frames: [CGImage] = []
    private var player = SaverPlayer()
    /// Bumped on every start and stop: a render that finishes for an
    /// earlier generation is dropped.
    private var generation = 0
    /// At most this many full-size frames are kept: the applied stills
    /// first, then favorites, so memory stays a few frames wide.
    nonisolated public static let maxFrames = 4

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1 / 30
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1 / 30
    }

    public override func startAnimation() {
        super.startAnimation()
        generation &+= 1
        render()
    }

    /// Stopped: pending renders are dropped when they land, and the frames
    /// go so a restart starts from a fresh, consistent set.
    public override func stopAnimation() {
        super.stopAnimation()
        generation &+= 1
        frames = []
        player.replaceFrames(count: 0, now: Date())
    }

    public override var hasConfigureSheet: Bool { false }

    /// The applied documents first, then the favorites, rendered at this
    /// view's pixel size off the main thread; the result is taken only if
    /// the view has not been stopped or restarted since.
    private func render() {
        let expected = generation
        let paths = AppPaths.standard()
        let scale = window?.backingScaleFactor ?? 2
        let size = PixelSize(points: bounds.size, scale: scale)
        let side: Side = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        DispatchQueue.global(qos: .userInitiated).async {
            let applied = AppliedStore(fileURL: paths.applied).current
            let favorites = FavoritesStore(fileURL: paths.favorites).all.map(\.wallpaper)
            let renderer = WallpaperRenderer(images: ImportStore(directory: paths.imports, maxCacheBytes: 32 * 1024 * 1024))
            var documents = Array(Set(applied.byDisplay.values)).sorted { $0.seed < $1.seed }
            for favorite in favorites where !documents.contains(favorite) { documents.append(favorite) }
            if documents.isEmpty { documents = [.starter] }
            let context = RenderContext(size: size)
            let images = documents.prefix(Self.maxFrames).compactMap { renderer.render($0, side: side, context: context).cgImage }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.frames = images
                self.player.replaceFrames(count: images.count, now: Date())
                self.needsDisplay = true
            }
        }
    }

    public override func animateOneFrame() {
        if player.tick(now: Date(), interval: animationTimeInterval) { needsDisplay = true }
    }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext, let current = player.currentIndex, current < frames.count else { return }
        if let fading = player.fadingOutIndex, fading < frames.count {
            context.draw(frames[fading], in: bounds)
            context.setAlpha(player.blend)
        }
        context.draw(frames[current], in: bounds)
    }
}
