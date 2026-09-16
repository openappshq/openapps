import AppKit
import MacPaperCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Writes an export where the user asked, or asks where. The app's writes
/// the export folder and falls back to a save panel; the preview harness
/// writes nothing. `mayWrite` is asked right before any bytes are written,
/// after every wait of the exporter's own (a save panel left open): a
/// `false` answer throws `AppModel.Refused` and writes nothing.
protocol FileExporter {
    func export(_ data: Data, named name: String, to folder: URL, mayWrite: @escaping @MainActor () -> Bool) async throws -> URL
}

/// Picks an image to pixelize or dither. The app's is an open panel; the
/// harness's picks nothing.
protocol ImagePicker {
    func pickImage() async -> URL?
}

struct PanelFileExporter: FileExporter {
    func export(_ data: Data, named name: String, to folder: URL, mayWrite: @escaping @MainActor () -> Bool) async throws -> URL {
        guard mayWrite() else { throw AppModel.Refused() }
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
            // The panel may have stayed open across a deadline.
            guard mayWrite() else { throw AppModel.Refused() }
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

/// Where a `.macpaper` recipe file is read from or written to. The app's
/// are an open panel and a save panel; the harness's pick nothing.
protocol RecipeDialog {
    func pickRecipeFile() async -> URL?
    func saveRecipeFile(named name: String) async -> URL?
}

struct PanelRecipeDialog: RecipeDialog {
    static let type = UTType(exportedAs: RecipeDocument.typeIdentifier, conformingTo: .json)

    func pickRecipeFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.type, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a macPaper recipe."
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    func saveRecipeFile(named name: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [Self.type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
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

/// Where live applies land: the panel's header control. "Every display"
/// is the only display choice while "same on all displays" is on.
enum ApplyReach: String, CaseIterable, Hashable {
    case everyDisplay, thisDisplay, thisSpace

    var title: String {
        switch self {
        case .everyDisplay: "Every display"
        case .thisDisplay: "This display"
        case .thisSpace: "This Space only"
        }
    }

    var symbolName: String {
        switch self {
        case .everyDisplay: "rectangle.on.rectangle"
        case .thisDisplay: "rectangle"
        case .thisSpace: "rectangle.dashed"
        }
    }

    /// The choices that make sense with the setting and the displays.
    static func available(sameOnAllDisplays: Bool, displayCount: Int) -> [ApplyReach] {
        if sameOnAllDisplays || displayCount < 2 { return [.everyDisplay, .thisSpace] }
        return [.thisDisplay, .everyDisplay, .thisSpace]
    }

    var target: ApplyTarget {
        switch self {
        case .everyDisplay: ApplyTarget(scope: .allDisplays)
        case .thisDisplay: ApplyTarget()
        case .thisSpace: ApplyTarget(thisSpaceOnly: true)
        }
    }
}

/// Which section of the column shows.
enum PanelSection: String, CaseIterable, Hashable, Identifiable {
    case library, generators, palette, parameters, effects, export, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .generators: "Generators"
        case .palette: "Palette"
        case .parameters: "Parameters"
        case .effects: "Effects"
        case .export: "Export"
        case .history: "History"
        }
    }

    var symbolName: String {
        switch self {
        case .library: "books.vertical"
        case .generators: "wand.and.stars"
        case .palette: "paintpalette"
        case .parameters: "slider.horizontal.3"
        case .effects: "sparkles"
        case .export: "square.and.arrow.up"
        case .history: "clock.arrow.circlepath"
        }
    }
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
    /// What the panel says about an update; an official build binds the
    /// updater to it (UpdatesLaunch.swift), every other build leaves it silent.
    @ObservationIgnored let updates = UpdateStatus()
    @ObservationIgnored let favorites: FavoritesStore
    @ObservationIgnored let applied: AppliedStore
    @ObservationIgnored let imports: ImportStore
    @ObservationIgnored let blocklist: BlocklistStore
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored let renderer: WallpaperRenderer
    @ObservationIgnored let applier: WallpaperApplier
    @ObservationIgnored let exporter: any FileExporter
    @ObservationIgnored let imagePicker: any ImagePicker
    @ObservationIgnored let recipeDialog: any RecipeDialog
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

    /// The document being edited: shown, and applied to the desktop as it
    /// changes (live apply, below). Every edit goes through `edit`, the one
    /// gated entry (the license is asked at the edit, never remembered),
    /// or through `load`, which shows a document and lets live apply take
    /// it to the desktop.
    private(set) var draft: Wallpaper {
        didSet {
            guard draft != oldValue else { return }
            favoritesRevision &+= 1
            schedulePreview()
            scheduleDraftSave()
            scheduleLiveApply()
        }
    }

    /// Whether changes reach the desktop on their own. On in the app; the
    /// preview harness and the tests of the explicit actions turn it off.
    @ObservationIgnored var appliesLive = true
    /// How long after the last change a live apply starts.
    @ObservationIgnored var liveApplyDelay: Duration = .milliseconds(150)
    /// Where live applies land; the panel's header control.
    var reach: ApplyReach
    /// The section the column shows; kept across opens and shared by the
    /// notch panel and the popover.
    var panelSection: PanelSection = .library

    /// Changes the draft while the license allows generating, asked at the
    /// edit through `allowed()` — never a value a view captured when it was
    /// built — so a control retained across a deadline changes, renders and
    /// saves nothing; a refused edit says so in the status line. Returns
    /// whether the change landed.
    @discardableResult
    func edit(_ change: (inout Wallpaper) -> Void) -> Bool {
        guard allowed() else { return false }
        var copy = draft
        change(&copy)
        draft = copy
        return true
    }

    /// A binding into the draft that writes through `edit`.
    func binding<Value>(_ keyPath: WritableKeyPath<Wallpaper, Value>) -> Binding<Value> {
        Binding(get: { self.draft[keyPath: keyPath] }, set: { value in self.edit { $0[keyPath: keyPath] = value } })
    }

    /// Shows a document (a favorite, a shared link, a shuffle's result):
    /// viewing is never gated.
    func load(_ wallpaper: Wallpaper) {
        var copy = wallpaper
        copy.pinned = preferences.pins
        draft = copy
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
    @ObservationIgnored private var pendingPreview: PreviewRequest?
    @ObservationIgnored private var previewInFlight = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var exportWorkspace: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Live apply: the generation of the last change, the debounce (a
    /// scheduler the tests replace with a manual one), and the chain every
    /// apply queues on so they land one at a time.
    @ObservationIgnored private var liveGeneration = 0
    @ObservationIgnored private var liveToken: (any ScheduledToken)?
    @ObservationIgnored var liveScheduler: any DelayScheduler = TaskDelayScheduler()
    @ObservationIgnored private var applyChain: Task<Void, Never>?
    @ObservationIgnored private var queuedApplies = 0
    /// How many live applies were started; the tests read it.
    @ObservationIgnored private(set) var liveApplyCount = 0
    /// Runs on the main actor after an apply's render, before the
    /// generation check and any desktop call; the tests drive the
    /// "superseded while rendering" path through it.
    @ObservationIgnored var afterPrepare: @MainActor () -> Void = {}

    /// `starterRecipes` fill an absent library (the taste set on a fresh
    /// install); tests start empty.
    init(
        preferences: Preferences, license: LicenseStatus, paths: AppPaths, desktop: any DesktopApplier,
        exporter: any FileExporter, imagePicker: any ImagePicker, recipeDialog: any RecipeDialog = PanelRecipeDialog(),
        starterRecipes: [Recipe] = [], displays: @escaping @MainActor () -> [DisplayInfo]
    ) {
        self.preferences = preferences
        self.license = license
        self.exporter = exporter
        self.imagePicker = imagePicker
        self.recipeDialog = recipeDialog
        displaySource = displays
        favorites = RecipeLibrary(fileURL: paths.favorites, starters: starterRecipes)
        applied = AppliedStore(fileURL: paths.applied)
        imports = ImportStore(directory: paths.imports)
        blocklist = BlocklistStore(fileURL: paths.blocklist)
        history = HistoryStore(fileURL: paths.history)
        renderer = WallpaperRenderer(images: imports)
        applier = WallpaperApplier(applier: desktop, renderer: renderer, cache: RenderCache(), directory: paths.appliedImages)
        appliedState = applied.current
        var opening = applied.current.draft ?? .starter
        opening.pinned = preferences.pins
        draft = opening
        reach = preferences.sameOnAllDisplays ? .everyDisplay : .thisDisplay
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

    /// What a preview render is asked for.
    private struct PreviewRequest {
        let generation: Int
        let wallpaper: Wallpaper
        let context: RenderContext
        let scale: Double
        let side: Side
    }

    /// One preview render at a time: a request made while one is in flight
    /// waits as the single pending one (a newer request replaces it), and
    /// runs when the render lands. A slider dragged fast costs one render
    /// in flight and one queued, never a pile of stale ones.
    private func schedulePreview() {
        previewGeneration &+= 1
        let context = currentContext
        pendingPreview = PreviewRequest(
            generation: previewGeneration, wallpaper: draft, context: context,
            scale: Double(previewSize.width) / Double(context.size.width), side: shownSide
        )
        startPreviewIfIdle()
    }

    private func startPreviewIfIdle() {
        guard !previewInFlight, let request = pendingPreview else { return }
        pendingPreview = nil
        previewInFlight = true
        let renderer = renderer
        let cache = previewCache
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scaled = request.context.scaled(by: request.scale)
            let key = RenderCache.Key(wallpaper: request.wallpaper, side: request.side, context: scaled)
            let raster = cache.render(key) { renderer.render(request.wallpaper, side: request.side, context: request.context, scale: request.scale) }
            let readability = MenuBarReadability.assess(raster, stripHeight: scaled.menuBarStrip, side: request.side)
            let image = raster.cgImage
            await MainActor.run {
                guard let self else { return }
                self.previewInFlight = false
                if request.generation == self.previewGeneration, let image {
                    self.preview = image
                    self.previewWallpaper = request.wallpaper
                    self.previewSide = request.side
                    self.readability = readability
                }
                self.startPreviewIfIdle()
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

    /// The Generators list's view of the edited generator: a family for
    /// a pixel field, the kind otherwise.
    var generatorChoice: GeneratorChoice {
        get { GeneratorChoice(editedGenerator) }
        set {
            switch newValue {
            case .family(let family): fieldFamily = family
            case .kind(let kind): generatorKind = kind
            }
        }
    }

    /// The pixel-field family of the edited generator (nil for the other
    /// kinds); setting one switches to a field of that family, shared
    /// knobs kept.
    var fieldFamily: FieldFamily? {
        get { if case .field(let p) = editedGenerator { return p.family } else { return nil } }
        set {
            guard let newValue else { return }
            if case .field(let p) = editedGenerator {
                guard p.family != newValue else { return }
                editedGenerator = .field(p.inFamily(newValue))
            } else if case .field(let p) = Generator.default(.field, colors: editedGenerator.colors) {
                editedGenerator = .field(p.inFamily(newValue))
            }
        }
    }

    /// One knob of the edited pixel field.
    func setKnob(_ key: ParameterKey, _ value: Double) {
        guard case .field(var p) = editedGenerator else { return }
        p[key] = value
        editedGenerator = .field(p)
    }

    /// The base under the texture: a kind from the draft's colors, or
    /// the base as edited.
    var baseKind: BaseKind {
        get { draft.base.kind }
        set {
            guard newValue != draft.base.kind else { return }
            let colors = editedGenerator.colors
            edit { $0.base = BaseLayer.default(newValue, colors: colors) }
        }
    }

    func setBase(_ base: BaseLayer) {
        edit { $0.base = base }
    }

    // MARK: - Pins

    /// The parameters Shuffle keeps: the user's pins (Preferences), the
    /// draft mirroring them so a recipe or a share carries them.
    var pinnedKeys: Set<ParameterKey> { preferences.pins }

    func isPinned(_ key: ParameterKey) -> Bool { preferences.pins.contains(key) }

    /// Pinning is not generating: it works in every license state.
    func pin(_ key: ParameterKey) {
        guard !preferences.pins.contains(key) else { return }
        preferences.pins.insert(key)
        draft.pinned = preferences.pins
    }

    func unpin(_ key: ParameterKey) {
        guard preferences.pins.contains(key) else { return }
        preferences.pins.remove(key)
        draft.pinned = preferences.pins
    }

    func togglePin(_ key: ParameterKey) {
        if isPinned(key) { unpin(key) } else { pin(key) }
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

    /// What became of a typed seed.
    enum SeedEntry: Equatable {
        case set
        /// Not a whole number in range; the draft is unchanged.
        case notANumber
        /// The license refused; the status line says so, the draft is unchanged.
        case refused
    }

    /// Sets the seed the user typed, if it is one and the license allows.
    func setSeed(_ text: String) -> SeedEntry {
        guard allowed() else { return .refused }
        guard let seed = UInt64(text.trimmingCharacters(in: .whitespaces)) else { return .notANumber }
        edit { $0 = $0.reseeded(seed) }
        return .set
    }

    /// `#000000`, every finish, composition and pair off: exact zeros on
    /// every pixel of every display, whatever was set before.
    func useTrueBlack() {
        edit {
            $0.generator = .solid(SolidParameters(color: .black))
            $0.darkGenerator = nil
            $0.grain = 0
            $0.finish = Finish()
            $0.composition = .none
            $0.pair = .still
            $0.base = .none
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

    /// Replaces the edited generator's colors with `colors` (as many as it
    /// takes). Fewer than two distinct colors (a photo of one hue) become
    /// a ramp of the one, so no generator ever holds a single tone.
    func applyPalette(_ colors: [RGBAColor]) {
        guard !colors.isEmpty else { return }
        let colors = Palettes.usable(colors)
        editedGenerator = editedGenerator.withPalette(colors)
        // The base follows the palette's ground, in the base's own kind.
        let kind = draft.base.kind
        if kind != .none { edit { $0.base = BaseLayer.default(kind, colors: colors) } }
    }

    /// One of the preset palettes: the colors, and the top shade lifted
    /// where the menu bar would not read on a side (a small render, here).
    func applyPreset(_ palette: Palette) {
        guard allowed() else { return }
        applyPalette(palette.tones)
        let lifted = draft.liftingMenuBar(context: readabilityContext, renderer: renderer)
        if lifted != draft { edit { $0 = lifted } }
    }

    /// The current display's context at a small size, for readability checks.
    var readabilityContext: RenderContext {
        currentContext.scaled(by: 160 / Double(currentContext.size.width))
    }

    /// The preset the edited generator's colors come from, if any.
    var currentPreset: Palette? {
        Palettes.preset(matching: editedGenerator.colors)
    }

    /// The colors of the edited generator, as a binding the palette row edits.
    var paletteColors: Binding<[RGBAColor]> {
        Binding(
            get: { self.editedGenerator.colors },
            set: { colors in self.applyPalette(colors) }
        )
    }

    /// A preset palette, by name: the generator's tones and the base.
    func applyPalette(_ palette: Palette) {
        applyPalette(palette.tones)
    }

    /// The preset the draft's colors came from, or "Custom".
    var paletteName: String { Palettes.name(for: draft.generator.colors) }

    /// The Mac's accent color expanded into a palette.
    func useAccentPalette() {
        applyPalette(AccentPalette.make(from: accentColor()))
        show("Palette from the accent color.")
    }

    /// The dominant colors of a photo the user picks.
    func usePhotoPalette() async {
        guard allowed() else { return }
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
        guard allowed() else { return }
        guard let url = await imagePicker.pickImage() else { return }
        await importImage(at: url)
    }

    /// Decodes off the main actor, bounded by the import size (a huge photo
    /// is scaled down while decoding, never held whole). The license is
    /// asked before the decode (the picker may have stayed open across a
    /// deadline) and again before the draft takes the result.
    func importImage(at url: URL) async {
        guard allowed() else { return }
        let imports = imports
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ImageReference, any Error> in
            do { return .success(try imports.importImage(at: url)) } catch { return .failure(error) }
        }.value
        // Lapsed during the decode: the draft keeps its source. The store's
        // copy is content-addressed and may already belong to a favorite, so
        // it is left where it is.
        guard allowed() else { return }
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

    // MARK: - Recipes (the library) and never-show

    var isFavorite: Bool {
        _ = favoritesRevision
        return favorites.contains(draft)
    }

    var favoriteList: [Recipe] {
        _ = favoritesRevision
        return favorites.all
    }

    /// The library's recipe for the draft, if it is in it.
    var currentRecipe: Recipe? {
        _ = favoritesRevision
        return favorites.recipe(for: draft)
    }

    /// The draft's name: the library's, else "<palette> · <generator>".
    var recipeName: String {
        currentRecipe?.name ?? Recipe.defaultName(for: draft)
    }

    /// Saves the draft as a recipe under a name (renames it when it is
    /// in the library already). Saving is not generating: every license
    /// state allows it.
    func saveRecipe(named name: String) {
        do {
            let recipe = try favorites.add(draft, named: name)
            favoritesRevision &+= 1
            show("Saved “\(recipe.name)”.")
        } catch {
            show("Couldn’t save the recipe: \(error.localizedDescription)", tone: .error)
        }
    }

    func renameRecipe(_ recipe: Recipe, to name: String) {
        do {
            try favorites.rename(recipe.id, to: name)
            favoritesRevision &+= 1
        } catch {
            show("Couldn’t rename: \(error.localizedDescription)", tone: .error)
        }
    }

    /// Writes the draft as a `.macpaper` file where the user says.
    func exportRecipe() async {
        let document = RecipeDocument(name: recipeName, palette: paletteName, wallpaper: draft)
        guard let url = await recipeDialog.saveRecipeFile(named: document.fileName) else { return }
        do {
            try document.fileData().write(to: url, options: .atomic)
            show("Exported \(url.lastPathComponent).")
        } catch {
            show("Couldn’t export the recipe: \(error.localizedDescription)", tone: .error)
        }
    }

    /// Reads a `.macpaper` file the user picks into the library and the draft.
    func importRecipe() async {
        guard let url = await recipeDialog.pickRecipeFile() else { return }
        importRecipe(at: url)
    }

    /// A recipe file from anywhere (a drop, a double-click, the open
    /// panel): decoded within the share code's bounds, added to the
    /// library and shown. Viewing is never gated.
    func importRecipe(at url: URL) {
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ShareCode.maxDocumentBytes else {
                throw ShareCode.DecodeError.tooLong
            }
            let document = try RecipeDocument.decode(try Data(contentsOf: url))
            let recipe = try favorites.add(document.recipe)
            favoritesRevision &+= 1
            load(recipe.wallpaper)
            let note = recipe.wallpaper.generator.source != nil ? " Its photo isn’t on this Mac: import one." : ""
            show("Imported “\(recipe.name)”.\(note)")
        } catch {
            show(error.localizedDescription, tone: .error)
        }
    }

    /// A recipe (the draft by default) as a `.macpaper` file in a
    /// temporary folder, for dragging out of the panel; nil when it
    /// cannot be written.
    func recipeDragURL(for recipe: Recipe? = nil) -> URL? {
        let document = recipe.map(RecipeDocument.init) ?? RecipeDocument(name: recipeName, palette: paletteName, wallpaper: draft)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-drag-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let url = folder.appendingPathComponent(document.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try document.fileData().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
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

    func removeFavorite(_ favorite: Recipe) {
        try? favorites.remove(favorite.wallpaper)
        favoritesRevision &+= 1
    }

    /// The star on a history entry: any document, not only the draft.
    func toggleFavoriteOf(_ wallpaper: Wallpaper) {
        do {
            let now = try favorites.toggle(wallpaper)
            favoritesRevision &+= 1
            show(now ? "Added to the library." : "Removed from the library.")
        } catch {
            show("Couldn’t save favorites: \(error.localizedDescription)", tone: .error)
        }
    }

    func load(_ favorite: Recipe) {
        load(favorite.wallpaper)
    }

    /// The Library's Save: the draft as a favorite under a name (empty:
    /// the derived title). A document already saved is renamed.
    /// The Library's rename: an empty name goes back to the derived one.
    func rename(_ favorite: Recipe, to name: String) {
        renameRecipe(favorite, to: name)
    }

    /// The name the Library's field starts with: the recipe's, or the
    /// derived name of the draft.
    var recipeTitle: String { recipeName }

    /// Never show a favorite: blocked for shuffle and dropped from the
    /// list; the draft is left alone.
    func neverShow(_ favorite: Recipe) {
        do {
            try blocklist.add(favorite.wallpaper)
            try? favorites.remove(favorite.wallpaper)
            favoritesRevision &+= 1
            show("Never shown again by shuffle.")
        } catch {
            show("Couldn’t save: \(error.localizedDescription)", tone: .error)
        }
    }

    // MARK: - Thumbnails

    /// Small renders of documents for the lists and grids, by document,
    /// rendered once off the main actor. The harness warms them before it
    /// draws (`ImageRenderer` runs no tasks).
    private(set) var thumbnails: [Wallpaper: CGImage] = [:]
    @ObservationIgnored private var thumbnailTasks: Set<Wallpaper> = []
    nonisolated static let thumbnailSize = PixelSize(width: Int(PanelLayout.thumbnail * 2), height: Int(PanelLayout.thumbnail * 1.25))

    /// The thumbnail, or nil while it renders (the view re-reads when it lands).
    func thumbnail(for wallpaper: Wallpaper) -> CGImage? {
        if let image = thumbnails[wallpaper] { return image }
        guard !thumbnailTasks.contains(wallpaper) else { return nil }
        thumbnailTasks.insert(wallpaper)
        let renderer = renderer
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                renderer.render(wallpaper, side: .light, context: RenderContext(size: Self.thumbnailSize, menuBarStrip: 4)).cgImage
            }.value
            guard let self else { return }
            self.thumbnailTasks.remove(wallpaper)
            if let image { self.thumbnails[wallpaper] = image }
        }
        return nil
    }

    /// Renders the thumbnails of these documents and waits for them.
    func prepareThumbnails(for wallpapers: [Wallpaper]) async {
        let renderer = renderer
        for wallpaper in wallpapers where thumbnails[wallpaper] == nil {
            let image = await Task.detached(priority: .utility) {
                renderer.render(wallpaper, side: .light, context: RenderContext(size: Self.thumbnailSize, menuBarStrip: 4)).cgImage
            }.value
            if let image { thumbnails[wallpaper] = image }
        }
    }

    // MARK: - History

    var historyList: [HistoryEntry] {
        _ = favoritesRevision
        return history.all
    }

    func removeHistory(_ entry: HistoryEntry) {
        try? history.remove(entry)
        favoritesRevision &+= 1
    }

    func clearHistory() {
        try? history.removeAll()
        favoritesRevision &+= 1
    }

    /// Never show this: blocked for shuffle, dropped from the favorites,
    /// and the panel moves on to a new seed of it — a new document, so only
    /// while the license allows generating; restricted, the blocked one
    /// stays shown.
    func neverShowThis() {
        do {
            try blocklist.add(draft)
            try? favorites.remove(draft)
            favoritesRevision &+= 1
            show("Never shown again by shuffle.")
            if license.hasAccess() { load(draft.reseeded()) }
        } catch {
            show("Couldn’t save: \(error.localizedDescription)", tone: .error)
        }
    }

    func clearBlocklist() {
        try? blocklist.removeAll()
        favoritesRevision &+= 1
    }

    // MARK: - Sharing

    /// `macpaper://s/<code>` on the pasteboard: the draft (named as the
    /// library names it), or a favorite.
    func shareLink(for wallpaper: Wallpaper? = nil) {
        let wallpaper = wallpaper ?? draft
        do {
            let recipe = favorites.recipe(for: wallpaper)
            let url = try ShareCode.url(for: RecipeDocument(name: recipe?.name ?? Recipe.defaultName(for: wallpaper), palette: Palettes.name(for: wallpaper.generator.colors), wallpaper: wallpaper))
            copyToPasteboard(url.absoluteString)
            let note = wallpaper.generator.source != nil || wallpaper.darkGenerator?.source != nil ? " The photo is not in it; the receiver sees the background." : ""
            show("Link copied.\(note)")
        } catch {
            show("Couldn’t make the link: \(error.localizedDescription)", tone: .error)
        }
    }

    /// A link opened from anywhere: the recipe becomes the draft.
    func open(sharedLink url: URL) {
        do {
            let document = try ShareCode.decode(url: url)
            load(document.wallpaper)
            let note = draft.generator.source != nil ? " Its photo isn’t on this Mac: import one." : ""
            show("Opened “\(document.name)”.\(note)")
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

    /// Whether Shuffle and Export may run now (the license). Applies queue
    /// behind one another, so one in flight blocks nothing. What a view
    /// reads to draw its buttons; every action asks `allowed()` again at
    /// the click.
    var canAct: Bool { license.hasAccess() }

    /// What a refused action says.
    static let restrictedMessage = "Not done: the license doesn’t allow making wallpapers right now."

    /// Thrown by an exporter whose `mayWrite` answered no.
    struct Refused: Error {}

    /// The license, asked at the moment of the action — never a value a
    /// view captured when it was built — so a click after a deadline that
    /// no timer has delivered yet does nothing but say why.
    private func allowed() -> Bool {
        if license.hasAccess() { return true }
        show(Self.restrictedMessage, tone: .error)
        return false
    }

    /// Applies the draft to this display, or to every display; "same on all
    /// displays" makes both the same. "This Space only" takes the display
    /// off the pin until the next every-Space apply. The explicit form:
    /// a pending live apply is dropped, since this lands the same draft.
    func apply(_ target: ApplyTarget = ApplyTarget()) {
        guard allowed() else { return }
        cancelLiveApply()
        let scope = target.scope ?? currentDisplay.map { .display($0.id) } ?? .allDisplays
        let plan = ApplyScope.plan(draft, scope: scope, displays: displays, sameOnAllDisplays: preferences.sameOnAllDisplays)
        run(plan, verb: target.thisSpaceOnly ? "Applied to this Space" : "Applied", perSpace: target.thisSpaceOnly)
    }

    /// Live apply: every change to the draft (a slider, a palette, a
    /// generator, a loaded favorite) reaches the desktop on its own,
    /// `liveApplyDelay` after the last one. The last state wins: a change
    /// during the wait restarts it, a change during a render leaves that
    /// render's files discarded before any desktop call, and applies queue
    /// one behind another. Restricted, nothing is applied; the license
    /// card in the panel says why, so the line stays quiet here.
    private func scheduleLiveApply() {
        guard appliesLive else { return }
        liveGeneration &+= 1
        let generation = liveGeneration
        liveToken?.cancel()
        liveToken = liveScheduler.schedule(after: liveApplyDelay) { [weak self] in
            guard let self, generation == self.liveGeneration else { return }
            self.liveApply(generation: generation)
        }
    }

    private func liveApply(generation: Int) {
        guard license.hasAccess(), !displays.isEmpty else { return }
        let target = reach.target
        let scope = target.scope ?? currentDisplay.map { .display($0.id) } ?? .allDisplays
        let plan = ApplyScope.plan(draft, scope: scope, displays: displays, sameOnAllDisplays: preferences.sameOnAllDisplays)
        liveApplyCount += 1
        run(plan, verb: nil, perSpace: target.thisSpaceOnly, generation: generation)
    }

    /// Drops a pending live apply, and marks one in flight as superseded:
    /// an explicit action lands the draft itself.
    private func cancelLiveApply() {
        liveToken?.cancel()
        liveToken = nil
        liveGeneration &+= 1
    }

    /// A curated document, applied at once (this display, or all of them
    /// while "same on all displays" is on), and shown as the draft. When
    /// the draw finds nothing the gate passes (the pins leave too little
    /// room), the desktop keeps what it shows and the panel says so.
    func shuffle(seed: UInt64 = .randomSeed()) {
        guard allowed() else { return }
        var generator = SeededGenerator(seed: seed)
        let targets = preferences.sameOnAllDisplays ? displays : currentDisplay.map { [$0] } ?? displays
        guard let plan = shufflePlan(for: targets, using: &generator) else { return }
        if let mine = currentDisplay.flatMap({ plan[$0] }) ?? plan.values.first { load(mine) }
        cancelLiveApply()
        run(plan, verb: "Shuffled", perSpace: false)
    }

    /// The scheduled shuffle: every display, per the settings, without
    /// touching the draft unless the panel shows an applied document.
    func scheduledShuffle() {
        guard license.hasAccess(), !displays.isEmpty else { return }
        var generator = SeededGenerator(seed: .randomSeed())
        guard let plan = shufflePlan(for: displays, using: &generator) else { return }
        let draftWasApplied = currentApplied == draft
        if draftWasApplied, let mine = currentDisplay.flatMap({ plan[$0] }) {
            load(mine)
            cancelLiveApply()
        }
        run(plan, verb: "Shuffled", perSpace: false)
    }

    /// A plan with nothing never-showed in it, or nil (the status line
    /// says why): every favorite blocked, the curated draw landing on the
    /// list twice, or the draw finding nothing better than what is shown.
    /// A display with nothing better keeps its wallpaper. A random pick
    /// is a curated one that keeps the draft's pins, gated with the app's
    /// renderer (a pinned photo renders) on each display's own context.
    /// Two rounds at most: the curated draw is already bounded inside.
    private func shufflePlan(for targets: [DisplayInfo], using generator: inout SeededGenerator) -> [DisplayInfo: Wallpaper]? {
        let favorites = blocklist.filter(self.favorites.all.map(\.wallpaper))
        for _ in 0..<2 {
            let plan = ShufflePlanner.plan(
                displays: targets, current: currentByDisplay, favorites: favorites,
                favoritesOnly: preferences.favoritesOnly, sameOnAllDisplays: preferences.sameOnAllDisplays, template: draft,
                renderer: renderer, context: { $0.renderContext }, using: &generator
            )
            guard !plan.isEmpty else {
                show(displays.isEmpty ? "No display to apply to." : (preferences.favoritesOnly && !favorites.isEmpty ? "Nothing left to shuffle to: every choice is on the never-show list." : Shuffle.nothingBetterMessage), tone: .error)
                return nil
            }
            if plan.values.allSatisfy({ !blocklist.contains($0) }) { return plan }
        }
        show("Nothing left to shuffle to: every choice is on the never-show list.", tone: .error)
        return nil
    }

    private var currentByDisplay: [DisplayID: Wallpaper] {
        Dictionary(uniqueKeysWithValues: displays.compactMap { display in appliedState.wallpaper(for: display.id).map { (display.id, $0) } })
    }

    /// Renders and writes off the main actor (`prepare`), then commits each
    /// display's file to the desktop here, asking the license before every
    /// one — and again before the fallback still a display that refused the
    /// HEIC gets: a deadline crossed while rendering, between two displays
    /// or between the refusal and the fallback leaves the rest undone and
    /// discarded, the desktop as it was.
    ///
    /// Applies queue on one chain and land one at a time; `isApplying` is
    /// true from the moment one is queued until the chain drains. A live
    /// apply carries its `generation`: superseded while it waited, it is
    /// skipped; superseded while it rendered, its files are discarded
    /// before any desktop call. `verb` nil says nothing on success (live
    /// applies; the preview's tag says "on the desktop").
    private func run(_ plan: [DisplayInfo: Wallpaper], verb: String?, perSpace: Bool, generation: Int? = nil) {
        guard !plan.isEmpty else {
            show(displays.isEmpty ? "No display to apply to." : "Nothing left to shuffle to: every choice is on the never-show list.", tone: .error)
            return
        }
        enqueue { [weak self] in
            guard let self, generation == nil || generation == self.liveGeneration else { return }
            await self.perform(plan, verb: verb, perSpace: perSpace, generation: generation)
        }
    }

    /// Queues work on the apply chain; `isApplying` holds until it drains.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        queuedApplies += 1
        isApplying = true
        let previous = applyChain
        applyChain = Task { [weak self] in
            await previous?.value
            await work()
            guard let self else { return }
            self.queuedApplies -= 1
            if self.queuedApplies == 0 { self.isApplying = false }
        }
    }

    private func perform(_ plan: [DisplayInfo: Wallpaper], verb: String?, perSpace: Bool, generation: Int?) async {
        let applier = applier
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<WallpaperApplier.Prepared, any Error> in
            do { return .success(try applier.prepare(plan)) } catch { return .failure(error) }
        }.value
        let prepared: WallpaperApplier.Prepared
        switch outcome {
        case .success(let value): prepared = value
        case .failure(let error):
            show(error.localizedDescription, tone: .error)
            return
        }
        afterPrepare()
        if let generation, generation != liveGeneration {
            // A newer change is on its way: this render never reaches a desktop.
            for image in prepared.images { applier.discard(image) }
            return
        }
        let committed = await commit(prepared, access: { [weak self] in self?.license.hasAccess() ?? false })
        record(committed.applied, perSpace: perSpace)
        if committed.refused {
            show(Self.restrictedMessage, tone: .error)
        } else if !committed.failures.isEmpty {
            show(WallpaperApplier.Failure(applied: committed.applied, failures: committed.failures).localizedDescription, tone: .error)
        } else if let verb {
            let images = committed.applied
            let fallbacks = images.filter { $0.format == .fallbackStill }.count
            var text = images.count == 1 ? "\(verb)." : "\(verb) to \(images.count) displays."
            if fallbacks > 0 { text += " \(fallbacks == 1 ? "One display" : "\(fallbacks) displays") took a still instead of the pair; macPaper swaps it on theme change while it runs." }
            show(text)
        }
    }

    /// What a round of commits came to.
    private struct Committed {
        var applied: [AppliedImage] = []
        var failures: [(DisplayID, String)] = []
        /// The license refused before some display: that one and the rest
        /// were discarded.
        var refused = false
    }

    /// Commits prepared files one display at a time, asking `access` on the
    /// main actor right before each desktop call (which runs off it, so a
    /// slow display never holds the UI): the file itself, and — where the
    /// display refuses a dynamic file — the fallback still, rendered off
    /// the main actor in between and asked about again. Once refused, every
    /// remaining file is discarded.
    private func commit(_ prepared: WallpaperApplier.Prepared, access: @escaping @MainActor () -> Bool) async -> Committed {
        let applier = applier
        var committed = Committed(failures: prepared.failures)
        for image in prepared.images {
            guard !committed.refused, access() else {
                committed.refused = true
                applier.discard(image)
                continue
            }
            switch await Self.commit(image, with: applier) {
            case .success(let applied):
                committed.applied.append(applied)
            case .failure(let refused as WallpaperApplier.DynamicRefused):
                // The still takes a render: off the main actor, then asked again.
                let fallback = await Task.detached(priority: .userInitiated) { () -> Result<WallpaperApplier.PreparedImage, any Error> in
                    do { return .success(try applier.prepareFallback(for: refused.image)) } catch { return .failure(error) }
                }.value
                applier.discard(refused.image)
                switch fallback {
                case .success(let still):
                    guard access() else {
                        committed.refused = true
                        applier.discard(still)
                        continue
                    }
                    switch await Self.commit(still, with: applier) {
                    case .success(let applied):
                        committed.applied.append(applied)
                    case .failure(let error):
                        applier.discard(still)
                        committed.failures.append((image.displayID, error.localizedDescription))
                    }
                case .failure(let error):
                    committed.failures.append((image.displayID, error.localizedDescription))
                }
            case .failure(let error):
                applier.discard(image)
                committed.failures.append((image.displayID, error.localizedDescription))
            }
        }
        return committed
    }

    /// One desktop call, off the main actor.
    private nonisolated static func commit(_ image: WallpaperApplier.PreparedImage, with applier: WallpaperApplier) async -> Result<AppliedImage, any Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<AppliedImage, any Error> in
            do { return .success(try applier.commit(image)) } catch { return .failure(error) }
        }.value
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
        // The History section: one entry per look, newest first.
        for wallpaper in Set(images.map(\.wallpaper)) { try? history.record(wallpaper) }
        favoritesRevision &+= 1
    }

    /// Re-reads the applied file (the preview harness writes it directly).
    func reloadAppliedState() {
        appliedState = applied.current
    }

    /// The Mac's appearance changed: displays that took a fallback still
    /// get the other side, and the preview follows when it tracks the Mac.
    /// A display applied "this Space only" is left alone (the active Space
    /// may be another one, and macOS gives no Space identity), and so is a
    /// display that no longer shows macPaper's recorded file.
    func themeChanged() {
        if editingSide == nil { schedulePreview() }
        let side = systemAppearance()
        let state = appliedState
        let fallbacks = state.fallbackDisplayIDs.subtracting(state.perSpaceDisplayIDs)
        guard !fallbacks.isEmpty, !isApplying else { return }
        var pending: [DisplayInfo: Wallpaper] = [:]
        for display in displays where fallbacks.contains(display.id) {
            guard let document = state.wallpaper(for: display.id), document.pair == .lightDark,
                  let recorded = state.file(for: display.id) else { continue }
            // Only while the display still shows what macPaper recorded.
            if let shown = applier.applier.currentImageURL(for: display.id), shown.standardizedFileURL.path != recorded.standardizedFileURL.path { continue }
            pending[display] = document
        }
        let plan = pending
        guard !plan.isEmpty else { return }
        // The swap is an apply like any other: prepared off the main actor,
        // committed per display only while the license allows it now (a
        // restricted Mac keeps the side it has; the wallpaper stays).
        let applier = applier
        enqueue { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> WallpaperApplier.Prepared? in
                try? applier.prepare(plan, side: side)
            }.value
            guard let self, let prepared = outcome else { return }
            let committed = await self.commit(prepared, access: { [weak self] in self?.license.hasAccess() ?? false })
            for image in committed.applied {
                try? self.applied.update { $0.record(image, perSpace: false) }
            }
            self.appliedState = self.applied.current
        }
    }

    // MARK: - Export

    /// Exports the draft, or a favorite from the Library.
    func export(_ kind: ExportKind, of document: Wallpaper? = nil) {
        guard allowed(), !isExporting else { return }
        let wallpaper = document ?? draft
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
            // The render may have crossed a deadline; the exporter asks
            // again right before writing each file, after any panel of its
            // own. A refusal mid-way keeps the files already written.
            guard self.allowed() else { return }
            do {
                var last: URL?
                for (name, data) in files {
                    last = try await self.exporter.export(data, named: name, to: folder) { [weak self] in self?.allowed() ?? false }
                }
                if let last {
                    self.show(files.count == 1 ? "Exported \(last.lastPathComponent)." : "Exported \(files.count) files to \(folder.lastPathComponent).")
                    self.exportWorkspace(last)
                }
            } catch CocoaError.userCancelled {
                // Nothing to say.
            } catch is Refused {
                // `allowed()` has said why.
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
