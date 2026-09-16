import AppKit
import MacPaperCore
import ScreenSaver

/// The `macPaper.saver` module: shows the still the display has applied
/// and, with favorites saved, crossfades through them once a minute. Reads
/// the same documents the app keeps (`applied.json`, `favorites.json`,
/// `imports/`) through MacPaperCore and renders them at the screen's pixel
/// size; needs nothing from the app while it runs, and never writes.
@objc(MacPaperSaverView)
public final class MacPaperSaverView: ScreenSaverView {
    private var frames: [CGImage] = []
    private var index = 0
    private var previous: CGImage?
    /// 0…1 while crossfading, 1 when settled.
    private var blend: CGFloat = 1
    private var lastSwitch = Date()
    private let holdSeconds: TimeInterval = 60
    private let fadeSeconds: TimeInterval = 1.5
    private var rendering = false

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
        render()
    }

    public override var hasConfigureSheet: Bool { false }

    /// The applied documents first, then the favorites, rendered at this
    /// view's pixel size off the main thread.
    private func render() {
        guard !rendering else { return }
        rendering = true
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
            let images = documents.prefix(12).compactMap { renderer.render($0, side: side, context: context).cgImage }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.frames = images
                self.rendering = false
                self.lastSwitch = Date()
                self.needsDisplay = true
            }
        }
    }

    public override func animateOneFrame() {
        let now = Date()
        if blend < 1 {
            blend = min(1, blend + CGFloat(animationTimeInterval / fadeSeconds))
            needsDisplay = true
        } else if frames.count > 1, now.timeIntervalSince(lastSwitch) >= holdSeconds {
            previous = frames[index]
            index = (index + 1) % frames.count
            blend = 0
            lastSwitch = now
            needsDisplay = true
        }
    }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard !frames.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let current = frames[index]
        if blend < 1, let previous {
            context.draw(previous, in: bounds)
            context.setAlpha(blend)
        }
        context.draw(current, in: bounds)
    }
}
