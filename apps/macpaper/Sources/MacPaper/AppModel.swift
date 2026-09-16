import AppKit
import MacPaperCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Writes an export where the user asked, or asks where. The app's writes
/// the export folder and falls back to a save panel; the preview harness
/// writes nothing.
protocol FileExporter {
    func export(_ data: Data, named name: String, to folder: URL) async throws -> URL
}

/// Picks an image to pixelize or dither. The app's is an open panel; the
/// harness's picks nothing.
protocol ImagePicker {
    func pickImage() async -> URL?
}

struct PanelFileExporter: FileExporter {
    func export(_ data: Data, named name: String, to folder: URL) async throws -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            // The folder is gone or read-only: ask instead.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(filenameExtension: (name as NSString).pathExtension) ?? .data]
            NSApp.activate()
            guard panel.runModal() == .OK, let url = panel.url else { throw CocoaError(.userCancelled) }
            try data.write(to: url, options: .atomic)
            return url
        }
    }
}

struct PanelImagePicker: ImagePicker {
    func pickImage() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image."
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One line of feedback under the actions: what just happened, or why it
/// did not. Cleared after a moment unless it is an error.
struct StatusLine: Equatable {
    enum Tone: Equatable { case info, error }
    let text: String
    let tone: Tone
}

/// What Apply targets: a display or all of them, and whether the apply is
/// for the current Space only (off the pin) or every Space (kept by it).
struct ApplyTarget: Equatable {
    var scope: ApplyScope?
    var thisSpaceOnly = false
}

/// What Export writes.
enum ExportKind: String, CaseIterable, Hashable {
    case png, svg, heicPair, phonePair

    var title: String {
        switch self {
        case .png: "PNG"
        case .svg: "SVG"
        case .heicPair: "HEIC pair"
        case .phonePair: "Phone pair"
        }
    }
}

/// The app's state: the draft document the panel edits, its preview, the
/// displays, what each shows, the favorites, and the actions. Owns the
/// stores and the render pipeline; the views only read and call. Renders
/// run off the main actor and land back here by generation, so a slider
/// dragged faster than the renderer never shows a stale frame last.
@Observable
final class AppModel {
    @ObservationIgnored let preferences: Preferences
    @ObservationIgnored let license: LicenseStatus
    @ObservationIgnored let favorites: FavoritesStore
    @ObservationIgnored let applied: AppliedStore
    @ObservationIgnored let imports: ImportStore
    @ObservationIgnored let blocklist: BlocklistStore
    @ObservationIgnored let renderer: WallpaperRenderer
    @ObservationIgnored let applier: WallpaperApplier
    @ObservationIgnored let exporter: any FileExporter
    @ObservationIgnored let imagePicker: any ImagePicker
    @ObservationIgnored let previewCache = RenderCache(maxBytes: 48 * 1024 * 1024, maxEntries: 24)
    @ObservationIgnored private let displaySource: @MainActor () -> [DisplayInfo]
    /// The Mac's appearance, for which side the preview shows and the
    /// fallback swap; the harness sets it.
    @ObservationIgnored var systemAppearance: @MainActor () -> Side = {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
    /// The Mac's accent color, for the accent palette; the harness fixes it.
    @ObservationIgnored var accentColor: @MainActor () -> RGBAColor = {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return RGBAColor(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
    }
    /// The pasteboard the share link goes to; the harness prints instead.
    @ObservationIgnored var copyToPasteboard: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The document being edited: shown, and applied on Apply. Every edit
    /// goes through `edit`, the one gated entry (the license is asked at
    /// the edit, never remembered), or through `load`, which only shows.
    private(set) var draft: Wallpaper {
        didSet {
            guard draft != oldValue else { return }
            favoritesRevision &+= 1
            schedulePreview()
            scheduleDraftSave()
        }
    }

    /// Changes the draft while the license allows generating; refused
    /// edits are dropped (the panel shows the license card then anyway).
    func edit(_ change: (inout Wallpaper) -> Void) {
        guard license.hasAccess() else { return }
        var copy = draft
        change(&copy)
        draft = copy
    }

    /// A binding into the draft that writes through `edit`.
    func binding<Value>(_ keyPath: WritableKeyPath<Wallpaper, Value>) -> Binding<Value> {
        Binding(get: { self.draft[keyPath: keyPath] }, set: { value in self.edit { $0[keyPath: keyPath] = value } })
    }

    /// Shows a document (a favorite, a shared link, a shuffle's result):
    /// viewing is never gated.
    func load(_ wallpaper: Wallpaper) {
        draft = wallpaper
    }
    /// The side the panel edits and shows: the Mac's appearance until the
    /// user picks one.
    var editingSide: Side? {
        didSet { schedulePreview() }
    }
    /// The display the panel speaks for: its aspect for the preview, its
    /// target for "this display". Set by whichever surface opened; a change
    /// re-renders the preview at that display's aspect.
    var targetDisplay: DisplayID? {
        didSet { if targetDisplay != oldValue { schedulePreview() } }
    }
    private(set) var displays: [DisplayInfo] = []
    private(set) var preview: CGImage?
    private(set) var previewWallpaper: Wallpaper?
    private(set) var previewSide: Side = .light
    /// The menu-bar readability of the last preview.
    private(set) var readability: MenuBarReadability?
    private(set) var appliedState: AppliedState
    private(set) var status: StatusLine?
    private(set) var isApplying = false
    private(set) var isExporting = false
    /// Bumped when the favorites or the blocklist change, so `isFavorite`
    /// and the lists re-read.
    private var favoritesRevision = 0

    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var exportWorkspace: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    init(
        preferences: Preferences, license: LicenseStatus, paths: AppPaths, desktop: any DesktopApplier,
        exporter: any FileExporter, imagePicker: any ImagePicker, displays: @escaping @MainActor () -> [DisplayInfo]
    ) {
        self.preferences = preferences
        self.license = license
        self.exporter = exporter
        self.imagePicker = imagePicker
        displaySource = displays
        favorites = FavoritesStore(fileURL: paths.favorites)
        applied = AppliedStore(fileURL: paths.applied)
        imports = ImportStore(directory: paths.imports)
        blocklist = BlocklistStore(fileURL: paths.blocklist)
        renderer = WallpaperRenderer(images: imports)
        applier = WallpaperApplier(applier: desktop, renderer: renderer, cache: RenderCache(), directory: paths.appliedImages)
        appliedState = applied.current
        draft = applied.current.draft ?? .starter
        refreshDisplays()
        schedulePreview()
    }

    // MARK: - Displays

    func refreshDisplays() {
        displays = displaySource()
        if let targetDisplay, !displays.contains(where: { $0.id == targetDisplay }) { self.targetDisplay = nil }
        schedulePreview()
    }

    /// The display the preview and "this display" mean now.
    var currentDisplay: DisplayInfo? {
        displays.first { $0.id == targetDisplay } ?? displays.first(where: \.isMain) ?? displays.first
    }

    /// Whether the displays show different documents, so the preview says
    /// which one it is.
    var displaysDiffer: Bool {
        Set(displays.compactMap { appliedState.wallpaper(for: $0.id) }).count > 1
    }

    /// The document the current display shows, if any.
    var currentApplied: Wallpaper? {
        currentDisplay.flatMap { appliedState.wallpaper(for: $0.id) }
    }

    /// The render context of the current display, or a 14" one.
    var currentContext: RenderContext {
        currentDisplay?.renderContext ?? RenderContext(size: PixelSize(width: 3024, height: 1964), notch: .virtual, menuBarStrip: 64)
    }

    // MARK: - Preview

    /// The preview's size: the display's aspect, 480 pixels wide at most.
    var previewSize: PixelSize {
        currentContext.size.fitting(width: 480)
    }

    /// The side shown: the chosen one, else the Mac's appearance.
    var shownSide: Side { editingSide ?? systemAppearance() }

    private func schedulePreview() {
        previewGeneration &+= 1
        let generation = previewGeneration
        let wallpaper = draft
        let context = currentContext
        let scale = Double(previewSize.width) / Double(context.size.width)
        let side = shownSide
        let renderer = renderer
        let cache = previewCache
        previewTask?.cancel()
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let key = RenderCache.Key(wallpaper: wallpaper, side: side, context: context.scaled(by: scale))
            let raster = cache.render(key) { renderer.render(wallpaper, side: side, context: context, scale: scale) }
            let readability = MenuBarReadability.assess(raster, stripHeight: context.scaled(by: scale).menuBarStrip, side: side)
            guard !Task.isCancelled, let image = raster.cgImage else { return }
            await MainActor.run {
                guard let self, generation == self.previewGeneration else { return }
                self.preview = image
                self.previewWallpaper = wallpaper
                self.previewSide = side
                self.readability = readability
            }
        }
    }

    private func scheduleDraftSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let draft = self.draft
            try? self.applied.update { $0.draft = draft }
        }
    }

    // MARK: - Editing

    /// The generator of the side being edited: the light one, or the dark
    /// one (materialised from the derived one on the first edit).
    var editedGenerator: Generator {
        get { draft.generator(for: shownSide) }
        set {
            let side = shownSide
            edit { if side == .dark { $0.darkGenerator = newValue } else { $0.generator = newValue } }
        }
    }

    var generatorKind: GeneratorKind {
        get { editedGenerator.kind }
        set {
            guard newValue != editedGenerator.kind else { return }
            editedGenerator = .default(newValue, colors: editedGenerator.colors, source: editedGenerator.source)
        }
    }

    /// Derives the dark side from the light one again (drops the edits).
    func resetDarkSide() {
        edit { $0.darkGenerator = nil }
    }

    /// Makes the derived dark side editable as its own generator.
    func materializeDarkSide() {
        edit { if $0.darkGenerator == nil { $0.darkGenerator = $0.generator.darkened() } }
    }

    /// A new seed, same generator and parameters.
    func reseed() {
        edit { $0 = $0.reseeded() }
    }

    /// Sets the seed the user typed, if it is one.
    func setSeed(_ text: String) -> Bool {
        guard let seed = UInt64(text.trimmingCharacters(in: .whitespaces)) else { return false }
        edit { $0 = $0.reseeded(seed) }
        return true
    }

    /// `#000000`, every finish off: exact zeros.
    func useTrueBlack() {
        edit {
            $0.generator = .solid(SolidParameters(color: .black))
            $0.darkGenerator = nil
            $0.grain = 0
            $0.finish = Finish()
            if $0.composition == .pill { $0.composition = .none }
        }
    }

    /// Shades the top so the menu bar reads: the one-click fix.
    func shadeTheTop() {
        edit { $0.finish.topShade = 0.7 }
    }

    func setPair(_ pair: PairMode) {
        edit { $0.pair = pair }
    }

    func setFinish(_ change: (inout Finish) -> Void) {
        edit { change(&$0.finish) }
    }

    /// The focal point of a framed image, from a drag on the preview.
    func setFocus(_ point: Point) {
        let clamped = Point(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        switch editedGenerator {
        case .pixelize(var p):
            p.focus = clamped
            editedGenerator = .pixelize(p)
        case .dither(var p):
            p.focus = clamped
            editedGenerator = .dither(p)
        default:
            break
        }
    }

    /// Whether the edited generator frames an image (the focal point applies).
    var framesImage: Bool {
        switch editedGenerator {
        case .pixelize(let p): p.source != nil && p.fit == .fill
        case .dither(let p): p.source != nil && p.fit == .fill
        default: false
        }
    }

    var focus: Point? {
        switch editedGenerator {
        case .pixelize(let p): p.focus
        case .dither(let p): p.focus
        default: nil
        }
    }

    // MARK: - Colors

    /// Replaces the edited generator's colors with `colors` (as many as it takes).
    func applyPalette(_ colors: [RGBAColor]) {
        guard !colors.isEmpty else { return }
        switch editedGenerator {
        case .gradient(var p):
            let count = min(max(colors.count, 2), GradientParameters.stopRange.upperBound)
            p.stops = (0..<count).map { i in ColorStop(position: Double(i) / Double(count - 1), color: colors[i % colors.count]) }
            editedGenerator = .gradient(p)
        case .mesh(var p):
            p.colors = Array(colors.prefix(MeshParameters.colorRange.upperBound))
            editedGenerator = .mesh(p)
        case .pattern(var p):
            p.background = colors[0]
            p.foreground = colors.count > 1 ? colors[colors.count - 1] : p.foreground
            editedGenerator = .pattern(p)
        case .solid(var p):
            p.color = colors[0]
            editedGenerator = .solid(p)
        case .pixelize(var p):
            p.background = colors[0]
            editedGenerator = .pixelize(p)
        case .dither(var p):
            p.paper = colors[0]
            p.ink = colors.count > 1 ? colors[colors.count - 1] : p.ink
            editedGenerator = .dither(p)
        }
    }

    /// The Mac's accent color expanded into a palette.
    func useAccentPalette() {
        applyPalette(AccentPalette.make(from: accentColor()))
        show("Palette from the accent color.")
    }

    /// The dominant colors of a photo the user picks.
    func usePhotoPalette() async {
        guard let url = await imagePicker.pickImage() else { return }
        let outcome = await Task.detached(priority: .userInitiated) { () -> [RGBAColor]? in
            guard let raster = Raster.decode(at: url, maxPixelSize: 512) else { return nil }
            return PaletteExtractor.dominantColors(of: raster, count: 5)
        }.value
        guard let colors = outcome else {
            show("The file is not an image macOS can read.", tone: .error)
            return
        }
        applyPalette(colors)
        show("Palette from \(url.lastPathComponent).")
    }

    // MARK: - Images

    /// Imports an image for Pixelize or Dither, switching to one of them.
    func importImage() async {
        guard let url = await imagePicker.pickImage() else { return }
        await importImage(at: url)
    }

    /// Decodes off the main actor, bounded by the import size (a huge photo
    /// is scaled down while decoding, never held whole).
    func importImage(at url: URL) async {
        let imports = imports
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ImageReference, any Error> in
            do { return .success(try imports.importImage(at: url)) } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let reference):
            switch editedGenerator {
            case .pixelize(var p):
                p.source = reference
                editedGenerator = .pixelize(p)
            case .dither(var p):
                p.source = reference
                editedGenerator = .dither(p)
            default:
                var p = PixelizeParameters(source: reference)
                p.background = editedGenerator.colors.first ?? .black
                editedGenerator = .pixelize(p)
            }
            show("Imported \(url.lastPathComponent).")
        case .failure(let error):
            show(error.localizedDescription, tone: .error)
        }
    }

    /// Whether the edited generator references an image that is not in the
    /// store any more: the panel says so beside Import.
    var isSourceMissing: Bool {
        guard let source = editedGenerator.source else { return false }
        return !imports.hasImage(for: source)
    }

    // MARK: - Favorites and never-show

    var isFavorite: Bool {
        _ = favoritesRevision
        return favorites.contains(draft)
    }

    var favoriteList: [Favorite] {
        _ = favoritesRevision
        return favorites.all
    }

    var blockedCount: Int {
        _ = favoritesRevision
        return blocklist.count
    }

    func toggleFavorite() {
        do {
            let now = try favorites.toggle(draft)
            favoritesRevision &+= 1
            show(now ? "Added to favorites." : "Removed from favorites.")
        } catch {
            show("Couldn’t save favorites: \(error.localizedDescription)", tone: .error)
        }
    }

    func removeFavorite(_ favorite: Favorite) {
        try? favorites.remove(favorite.wallpaper)
        favoritesRevision &+= 1
    }

    func load(_ favorite: Favorite) {
        load(favorite.wallpaper)
    }

    /// Never show this: blocked for shuffle, dropped from the favorites,
    /// and the panel moves on to a new seed of it.
    func neverShowThis() {
        do {
            try blocklist.add(draft)
            try? favorites.remove(draft)
            favoritesRevision &+= 1
            show("Never shown again by shuffle.")
            load(draft.reseeded())
        } catch {
            show("Couldn’t save: \(error.localizedDescription)", tone: .error)
        }
    }

    func clearBlocklist() {
        try? blocklist.removeAll()
        favoritesRevision &+= 1
    }

    // MARK: - Sharing

    /// `macpaper://s/<code>` on the pasteboard.
    func shareLink() {
        do {
            let url = try ShareCode.url(for: draft)
            copyToPasteboard(url.absoluteString)
            let note = draft.generator.source != nil || draft.darkGenerator?.source != nil ? " The photo is not in it; the receiver sees the background." : ""
            show("Link copied.\(note)")
        } catch {
            show("Couldn’t make the link: \(error.localizedDescription)", tone: .error)
        }
    }

    /// A link opened from anywhere: the document becomes the draft.
    func open(sharedLink url: URL) {
        do {
            load(try ShareCode.decode(url: url))
            let note = draft.generator.source != nil ? " Its photo isn’t on this Mac: import one." : ""
            show("Opened a shared wallpaper.\(note)")
        } catch {
            show(error.localizedDescription, tone: .error)
        }
    }

    /// Remix: the loaded document with a new seed.
    func remix() {
        edit { $0 = $0.reseeded() }
        show("Remixed.")
    }

    // MARK: - Apply and shuffle

    /// Whether Apply, Shuffle and Export may run now (the license, and no
    /// apply in flight).
    var canAct: Bool { license.hasAccess() && !isApplying }

    /// Applies the draft to this display, or to every display; "same on all
    /// displays" makes both the same. "This Space only" takes the display
    /// off the pin until the next every-Space apply.
    func apply(_ target: ApplyTarget = ApplyTarget()) {
        guard license.hasAccess() else { return }
        let scope = target.scope ?? currentDisplay.map { .display($0.id) } ?? .allDisplays
        let plan = ApplyScope.plan(draft, scope: scope, displays: displays, sameOnAllDisplays: preferences.sameOnAllDisplays)
        run(plan, verb: target.thisSpaceOnly ? "Applied to this Space" : "Applied", perSpace: target.thisSpaceOnly)
    }

    /// A random document, applied at once (this display, or all of them
    /// while "same on all displays" is on), and shown as the draft.
    func shuffle() {
        guard license.hasAccess() else { return }
        var generator = SeededGenerator(seed: .randomSeed())
        let targets = preferences.sameOnAllDisplays ? displays : currentDisplay.map { [$0] } ?? displays
        let plan = shufflePlan(for: targets, using: &generator)
        if let mine = currentDisplay.flatMap({ plan[$0] }) ?? plan.values.first { load(mine) }
        run(plan, verb: "Shuffled", perSpace: false)
    }

    /// The scheduled shuffle: every display, per the settings, without
    /// touching the draft unless the panel shows an applied document.
    func scheduledShuffle() {
        guard license.hasAccess(), !displays.isEmpty else { return }
        var generator = SeededGenerator(seed: .randomSeed())
        let plan = shufflePlan(for: displays, using: &generator)
        let draftWasApplied = currentApplied == draft
        if draftWasApplied, let mine = currentDisplay.flatMap({ plan[$0] }) { load(mine) }
        run(plan, verb: "Shuffled", perSpace: false)
    }

    private func shufflePlan(for targets: [DisplayInfo], using generator: inout SeededGenerator) -> [DisplayInfo: Wallpaper] {
        let favorites = blocklist.filter(self.favorites.all.map(\.wallpaper))
        var plan: [DisplayInfo: Wallpaper] = [:]
        // A random pick that lands on the blocklist is drawn again, a few times.
        for _ in 0..<6 {
            plan = ShufflePlanner.plan(
                displays: targets, current: currentByDisplay, favorites: favorites,
                favoritesOnly: preferences.favoritesOnly, sameOnAllDisplays: preferences.sameOnAllDisplays, using: &generator
            )
            if plan.values.allSatisfy({ !blocklist.contains($0) }) { break }
        }
        return plan
    }

    private var currentByDisplay: [DisplayID: Wallpaper] {
        Dictionary(uniqueKeysWithValues: displays.compactMap { display in appliedState.wallpaper(for: display.id).map { (display.id, $0) } })
    }

    private func run(_ plan: [DisplayInfo: Wallpaper], verb: String, perSpace: Bool) {
        guard !plan.isEmpty else {
            show("No display to apply to.", tone: .error)
            return
        }
        guard !isApplying else { return }
        isApplying = true
        let applier = applier
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[AppliedImage], any Error> in
                do { return .success(try applier.apply(plan)) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.isApplying = false
            switch outcome {
            case .success(let images):
                self.record(images, perSpace: perSpace)
                let fallbacks = images.filter { $0.format == .fallbackStill }.count
                var text = images.count == 1 ? "\(verb)." : "\(verb) to \(images.count) displays."
                if fallbacks > 0 { text += " \(fallbacks == 1 ? "One display" : "\(fallbacks) displays") took a still instead of the pair; macPaper swaps it on theme change while it runs." }
                self.show(text)
            case .failure(let failure as WallpaperApplier.Failure):
                self.record(failure.applied, perSpace: perSpace)
                self.show(failure.localizedDescription, tone: .error)
            case .failure(let error):
                self.show(error.localizedDescription, tone: .error)
            }
        }
    }

    private func record(_ images: [AppliedImage], perSpace: Bool) {
        guard !images.isEmpty else { return }
        do {
            try applied.update { state in
                for image in images { state.record(image, perSpace: perSpace) }
                state.lastApplied = Date()
            }
        } catch {
            show("Applied, but couldn’t save the record: \(error.localizedDescription)", tone: .error)
        }
        appliedState = applied.current
    }

    /// Re-reads the applied file (the preview harness writes it directly).
    func reloadAppliedState() {
        appliedState = applied.current
    }

    /// The Mac's appearance changed: displays that took a fallback still
    /// get the other side, and the preview follows when it tracks the Mac.
    func themeChanged() {
        if editingSide == nil { schedulePreview() }
        let side = systemAppearance()
        let fallbacks = appliedState.fallbackDisplayIDs
        guard !fallbacks.isEmpty, !isApplying else { return }
        var pending: [DisplayInfo: Wallpaper] = [:]
        for display in displays where fallbacks.contains(display.id) {
            if let document = appliedState.wallpaper(for: display.id), document.pair == .lightDark { pending[display] = document }
        }
        let plan = pending
        guard !plan.isEmpty else { return }
        isApplying = true
        let applier = applier
        let perSpace = appliedState.perSpaceDisplayIDs
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> [AppliedImage] in
                (try? applier.apply(plan, side: side)) ?? []
            }.value
            guard let self else { return }
            self.isApplying = false
            for image in outcome {
                try? self.applied.update { $0.record(image, perSpace: perSpace.contains(image.display)) }
            }
            self.appliedState = self.applied.current
        }
    }

    // MARK: - Export

    func export(_ kind: ExportKind) {
        guard license.hasAccess(), !isExporting else { return }
        let wallpaper = draft
        let context = currentContext
        let renderer = renderer
        let folder = preferences.exportFolder
        isExporting = true
        Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) { () -> [(String, Data)] in
                switch kind {
                case .png:
                    guard let data = WallpaperExport.png(wallpaper, size: context.size, renderer: renderer) else { return [] }
                    return [(WallpaperExport.fileName(for: wallpaper, format: .png), data)]
                case .svg:
                    return [(WallpaperExport.fileName(for: wallpaper, format: .svg), Data(WallpaperExport.svg(wallpaper, size: context.size, renderer: renderer).utf8))]
                case .heicPair:
                    let light = renderer.render(wallpaper, side: .light, context: context)
                    let dark = renderer.render(wallpaper, side: .dark, context: context)
                    guard let data = try? DynamicDesktop.appearancePair(light: light, dark: dark) else { return [] }
                    return [("macPaper-\(wallpaper.generator.kind.rawValue)-\(wallpaper.seed)-pair.heic", data)]
                case .phonePair:
                    guard let desktop = WallpaperExport.png(wallpaper, size: context.size, renderer: renderer),
                          let phone = renderer.render(wallpaper, side: .light, context: RenderContext(size: PhoneCanvas.size, menuBarStrip: 1)).pngData() else { return [] }
                    return [
                        (WallpaperExport.fileName(for: wallpaper, format: .png), desktop),
                        ("macPaper-\(wallpaper.generator.kind.rawValue)-\(wallpaper.seed)-\(PhoneCanvas.name).png", phone),
                    ]
                }
            }.value
            guard let self else { return }
            defer { self.isExporting = false }
            guard !files.isEmpty else {
                self.show("Couldn’t render the export.", tone: .error)
                return
            }
            do {
                var last: URL?
                for (name, data) in files { last = try await self.exporter.export(data, named: name, to: folder) }
                if let last {
                    self.show(files.count == 1 ? "Exported \(last.lastPathComponent)." : "Exported \(files.count) files to \(folder.lastPathComponent).")
                    self.exportWorkspace(last)
                }
            } catch CocoaError.userCancelled {
                // Nothing to say.
            } catch {
                self.show("Couldn’t export: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    /// The harness never reveals in the Finder.
    func setExportReveal(_ reveal: @escaping (URL) -> Void) {
        exportWorkspace = reveal
    }

    // MARK: - Status

    func show(_ text: String, tone: StatusLine.Tone = .info) {
        status = StatusLine(text: text, tone: tone)
        statusTask?.cancel()
        guard tone == .info else { return }
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.status?.text == text else { return }
            self.status = nil
        }
    }

    func clearStatus() {
        statusTask?.cancel()
        status = nil
    }
}
