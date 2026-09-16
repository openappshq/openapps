import AppKit
import MacPaperCore
import Observation
import UniformTypeIdentifiers

/// Writes an export where the user asked, or asks where. The app's writes
/// the export folder and falls back to a save panel; the preview harness
/// writes nothing. `mayWrite` is asked right before any bytes are written,
/// after every wait of the exporter's own (a save panel left open): a
/// `false` answer throws `AppModel.Refused` and writes nothing.
protocol FileExporter {
    func export(_ data: Data, named name: String, to folder: URL, mayWrite: @escaping @MainActor () -> Bool) async throws -> URL
}

/// Picks an image to pixelize. The app's is an open panel; the harness's
/// picks nothing.
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
    /// What the panel says about an update; an official build binds the
    /// updater to it (UpdatesLaunch.swift), every other build leaves it silent.
    @ObservationIgnored let updates = UpdateStatus()
    @ObservationIgnored let favorites: FavoritesStore
    @ObservationIgnored let applied: AppliedStore
    @ObservationIgnored let imports: ImportStore
    @ObservationIgnored let renderer: WallpaperRenderer
    @ObservationIgnored let applier: WallpaperApplier
    @ObservationIgnored let exporter: any FileExporter
    @ObservationIgnored let imagePicker: any ImagePicker
    @ObservationIgnored let previewCache = RenderCache(maxBytes: 48 * 1024 * 1024, maxEntries: 24)
    @ObservationIgnored private let displaySource: @MainActor () -> [DisplayInfo]

    /// The document being edited: shown, and applied on Apply. Set here
    /// only by the model's own gated paths, by `load` (a favorite, which is
    /// browsing, not generating) and by fixtures; every editor binds
    /// `edited`, whose setter asks the license first.
    var draft: Wallpaper {
        didSet {
            guard draft != oldValue else { return }
            favoritesRevision &+= 1
            schedulePreview()
            scheduleDraftSave()
        }
    }

    /// The draft as the panel's editors see it: reads are the draft, and
    /// every write — a parameter, a color, the grain — asks `allowed()` at
    /// that moment, so a control retained across a deadline changes,
    /// renders and saves nothing.
    var edited: Wallpaper {
        get { draft }
        set {
            guard allowed() else { return }
            draft = newValue
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
            guard newValue != draft.generator.kind, allowed() else { return }
            draft.generator = .default(newValue, colors: draft.generator.colors)
        }
    }

    /// A new seed, same generator and parameters.
    func reseed() {
        guard allowed() else { return }
        draft = draft.reseeded()
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
        draft = draft.reseeded(seed)
        return .set
    }

    /// Imports an image for Pixelize, switching the generator to it.
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
    /// apply in flight). What a view reads to draw its buttons; every action
    /// asks `allowed()` again at the click.
    var canAct: Bool { license.hasAccess() && !isApplying }

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
    /// displays" makes both the same.
    func apply(_ scope: ApplyScope? = nil) {
        guard allowed() else { return }
        let scope = scope ?? currentDisplay.map { .display($0.id) } ?? .allDisplays
        let plan = ApplyScope.plan(draft, scope: scope, displays: displays, sameOnAllDisplays: preferences.sameOnAllDisplays)
        run(plan, verb: "Applied")
    }

    /// A random document, applied at once (this display, or all of them
    /// while "same on all displays" is on), and shown as the draft.
    func shuffle() {
        guard allowed() else { return }
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

    /// Renders and writes off the main actor (`prepare`), then commits each
    /// display's file to the desktop here, asking the license before every
    /// one: a deadline crossed while rendering, or between two displays,
    /// leaves the rest undone and discarded, the desktop as it was.
    private func run(_ plan: [DisplayInfo: Wallpaper], verb: String) {
        guard !plan.isEmpty else {
            show("No display to apply to.", tone: .error)
            return
        }
        guard !isApplying else { return }
        isApplying = true
        let applier = applier
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<WallpaperApplier.Prepared, any Error> in
                do { return .success(try applier.prepare(plan)) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            defer { self.isApplying = false }
            let prepared: WallpaperApplier.Prepared
            switch outcome {
            case .success(let value): prepared = value
            case .failure(let error):
                self.show(error.localizedDescription, tone: .error)
                return
            }
            var applied: [AppliedImage] = []
            var failures = prepared.failures
            var refused = false
            for image in prepared.images {
                guard !refused, self.license.hasAccess() else {
                    refused = true
                    applier.discard(image)
                    continue
                }
                do {
                    applied.append(try applier.commit(image))
                } catch {
                    failures.append((image.display, error.localizedDescription))
                }
            }
            self.record(applied)
            if refused {
                self.show(Self.restrictedMessage, tone: .error)
            } else if !failures.isEmpty {
                self.show(WallpaperApplier.Failure(applied: applied, failures: failures).localizedDescription, tone: .error)
            } else {
                self.show(applied.count == 1 ? "\(verb)." : "\(verb) to \(applied.count) displays.")
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
        guard allowed(), !isExporting else { return }
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
            // The render may have crossed a deadline; the exporter asks
            // again right before writing, after any panel of its own.
            guard self.allowed() else { return }
            do {
                let url = try await self.exporter.export(data, named: name, to: folder) { [weak self] in self?.allowed() ?? false }
                self.show("Exported \(url.lastPathComponent).")
                self.exportWorkspace(url)
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
