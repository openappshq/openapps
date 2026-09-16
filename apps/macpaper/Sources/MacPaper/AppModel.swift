import AppKit
import MacPaperCore
import Observation
import UniformTypeIdentifiers

/// Writes an export where the user asked, or asks where. The app's writes
/// the export folder and falls back to a save panel; the preview harness
/// writes nothing.
protocol FileExporter {
    func export(_ data: Data, named name: String, to folder: URL) async throws -> URL
}

/// Picks an image to pixelize. The app's is an open panel; the harness's
/// picks nothing.
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
        panel.message = "Choose an image to pixelize."
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
    @ObservationIgnored let renderer: WallpaperRenderer
    @ObservationIgnored let applier: WallpaperApplier
    @ObservationIgnored let exporter: any FileExporter
    @ObservationIgnored let imagePicker: any ImagePicker
    @ObservationIgnored let previewCache = RenderCache(maxBytes: 48 * 1024 * 1024, maxEntries: 24)
    @ObservationIgnored private let displaySource: @MainActor () -> [DisplayInfo]

    /// The document being edited: shown, and applied on Apply.
    var draft: Wallpaper {
        didSet {
            guard draft != oldValue else { return }
            favoritesRevision &+= 1
            schedulePreview()
            scheduleDraftSave()
        }
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
    private(set) var appliedState: AppliedState
    private(set) var status: StatusLine?
    private(set) var isApplying = false
    private(set) var isExporting = false
    /// Bumped when the favorites change, so `isFavorite` re-reads.
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

    // MARK: - Preview

    /// The preview's size: the display's aspect, 480 pixels wide at most.
    var previewSize: PixelSize {
        (currentDisplay?.pixelSize ?? PixelSize(width: 3024, height: 1964)).fitting(width: 480)
    }

    private func schedulePreview() {
        previewGeneration &+= 1
        let generation = previewGeneration
        let wallpaper = draft
        let full = currentDisplay?.pixelSize ?? PixelSize(width: 3024, height: 1964)
        let scale = Double(previewSize.width) / Double(full.width)
        let renderer = renderer
        let cache = previewCache
        previewTask?.cancel()
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let key = RenderCache.Key(wallpaper: wallpaper, size: full.scaled(by: scale))
            let raster = cache.render(key) { renderer.render(wallpaper, size: full, scale: scale) }
            guard !Task.isCancelled, let image = raster.cgImage else { return }
            await MainActor.run {
                guard let self, generation == self.previewGeneration else { return }
                self.preview = image
                self.previewWallpaper = wallpaper
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

    var generatorKind: GeneratorKind {
        get { draft.generator.kind }
        set {
            guard newValue != draft.generator.kind else { return }
            draft.generator = .default(newValue, colors: draft.generator.colors)
        }
    }

    /// A new seed, same generator and parameters.
    func reseed() {
        draft = draft.reseeded()
    }

    /// Sets the seed the user typed, if it is one.
    func setSeed(_ text: String) -> Bool {
        guard let seed = UInt64(text.trimmingCharacters(in: .whitespaces)) else { return false }
        draft = draft.reseeded(seed)
        return true
    }

    /// Imports an image for Pixelize, switching the generator to it.
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
            if case .pixelize(var p) = draft.generator {
                p.source = reference
                draft.generator = .pixelize(p)
            } else {
                var p = PixelizeParameters(source: reference)
                p.background = draft.generator.colors.first ?? .black
                draft.generator = .pixelize(p)
            }
            show("Imported \(url.lastPathComponent).")
        case .failure(let error):
            show(error.localizedDescription, tone: .error)
        }
    }

    /// Whether the draft references an image that is not in the store any
    /// more: the panel says so beside Import.
    var isSourceMissing: Bool {
        if case .pixelize(let p) = draft.generator, let source = p.source {
            return !imports.hasImage(for: source)
        }
        return false
    }

    // MARK: - Favorites

    var isFavorite: Bool {
        _ = favoritesRevision
        return favorites.contains(draft)
    }

    var favoriteList: [Favorite] {
        _ = favoritesRevision
        return favorites.all
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
        draft = favorite.wallpaper
    }

    // MARK: - Apply and shuffle

    /// Whether Apply, Shuffle and Export may run now (the license, and no
    /// apply in flight).
    var canAct: Bool { license.hasAccess() && !isApplying }

    /// Applies the draft to this display, or to every display; "same on all
    /// displays" makes both the same.
    func apply(_ scope: ApplyScope? = nil) {
        guard license.hasAccess() else { return }
        let scope = scope ?? currentDisplay.map { .display($0.id) } ?? .allDisplays
        let plan = ApplyScope.plan(draft, scope: scope, displays: displays, sameOnAllDisplays: preferences.sameOnAllDisplays)
        run(plan, verb: "Applied")
    }

    /// A random document, applied at once (this display, or all of them
    /// while "same on all displays" is on), and shown as the draft.
    func shuffle() {
        guard license.hasAccess() else { return }
        var generator = SeededGenerator(seed: .randomSeed())
        let targets = preferences.sameOnAllDisplays ? displays : currentDisplay.map { [$0] } ?? displays
        let plan = ShufflePlanner.plan(
            displays: targets, current: currentByDisplay, favorites: favorites.all.map(\.wallpaper),
            favoritesOnly: preferences.favoritesOnly, sameOnAllDisplays: preferences.sameOnAllDisplays, using: &generator
        )
        if let mine = currentDisplay.flatMap({ plan[$0] }) ?? plan.values.first { draft = mine }
        run(plan, verb: "Shuffled")
    }

    /// The scheduled shuffle: every display, per the settings, without
    /// touching the draft unless the panel shows an applied document.
    func scheduledShuffle() {
        guard license.hasAccess(), !displays.isEmpty else { return }
        var generator = SeededGenerator(seed: .randomSeed())
        let plan = ShufflePlanner.plan(
            displays: displays, current: currentByDisplay, favorites: favorites.all.map(\.wallpaper),
            favoritesOnly: preferences.favoritesOnly, sameOnAllDisplays: preferences.sameOnAllDisplays, using: &generator
        )
        let draftWasApplied = currentApplied == draft
        if draftWasApplied, let mine = currentDisplay.flatMap({ plan[$0] }) { draft = mine }
        run(plan, verb: "Shuffled")
    }

    private var currentByDisplay: [DisplayID: Wallpaper] {
        Dictionary(uniqueKeysWithValues: displays.compactMap { display in appliedState.wallpaper(for: display.id).map { (display.id, $0) } })
    }

    private func run(_ plan: [DisplayInfo: Wallpaper], verb: String) {
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
                self.record(images)
                self.show(images.count == 1 ? "\(verb)." : "\(verb) to \(images.count) displays.")
            case .failure(let failure as WallpaperApplier.Failure):
                self.record(failure.applied)
                self.show(failure.localizedDescription, tone: .error)
            case .failure(let error):
                self.show(error.localizedDescription, tone: .error)
            }
        }
    }

    private func record(_ images: [AppliedImage]) {
        guard !images.isEmpty else { return }
        do {
            try applied.update { state in
                for image in images { state.set(image.wallpaper, for: image.display) }
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

    // MARK: - Export

    func export(_ format: WallpaperExport.Format) {
        guard license.hasAccess(), !isExporting else { return }
        let wallpaper = draft
        let size = currentDisplay?.pixelSize ?? PixelSize(width: 3024, height: 1964)
        let renderer = renderer
        let name = WallpaperExport.fileName(for: wallpaper, format: format)
        let folder = preferences.exportFolder
        isExporting = true
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                switch format {
                case .png: WallpaperExport.png(wallpaper, size: size, renderer: renderer)
                case .svg: Data(WallpaperExport.svg(wallpaper, size: size, renderer: renderer).utf8)
                }
            }.value
            guard let self else { return }
            defer { self.isExporting = false }
            guard let data else {
                self.show("Couldn’t render the export.", tone: .error)
                return
            }
            do {
                let url = try await self.exporter.export(data, named: name, to: folder)
                self.show("Exported \(url.lastPathComponent).")
                self.exportWorkspace(url)
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
