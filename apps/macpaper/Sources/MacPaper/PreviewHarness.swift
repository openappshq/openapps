#if DEBUG
import AppKit
import MacPaperCore
import OpenAppsLicensing
import ServiceManagement
import SwiftUI

/// Renders the panel (on a drawn display with its menu bar, over a
/// wallpaper: from the notch, and under the menu-bar item on a notched
/// and a plain display, capped and scrolled on a small one), the
/// first-run glow, the guide's panel step, the restricted state and the
/// settings window to PNGs, in light and dark appearance:
/// `MacPaper --preview <directory>`.
/// Debug builds only; release binaries contain none of it.
///
/// Nothing real is touched: no status item, a throwaway defaults suite and
/// a temporary Application Support folder (both removed at the end), a
/// recording desktop applier (the desktop never changes), an exporter and
/// an image picker that write and open nothing, a login item that registers
/// only in memory, no hotkey, no shuffle timer, and no window: the views
/// are drawn with `ImageRenderer` (see `write`).
@MainActor
final class PreviewHarness {
    /// The throwaway suite lives under the temporary directory (a suite
    /// named by an absolute path is kept at that path), never in
    /// ~/Library/Preferences, where a removed domain would be written back
    /// as an empty plist.
    nonisolated static let suiteDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("space.openapps.macpaper.preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    nonisolated static let suite = suiteDirectory.appendingPathComponent("defaults").path

    private let outputDirectory: URL
    private let defaults: UserDefaults
    private let paths: AppPaths
    private let preferences: Preferences
    private let license = LicenseStatus()
    private let model: AppModel
    private let loginItem: LoginItem
    private let hotkeys = HotkeyCenter()
    private let desktop = RecordingApplier()

    /// The displays the preview pretends to have: a 14" MacBook Pro with
    /// its notch, and an external display.
    static let displays = [
        DisplayInfo(id: 1, name: "Built-in Retina Display", pointSize: CGSize(width: 1512, height: 982), scale: 2, notchWidth: 252, isMain: true),
        DisplayInfo(id: 2, name: "Studio Display", pointSize: CGSize(width: 2560, height: 1440), scale: 2),
    ]

    private struct NoExport: FileExporter {
        func export(_ data: Data, named name: String, to folder: URL, mayWrite: @escaping @MainActor () -> Bool) async throws -> URL {
            print("PREVIEW_EXPORT \(name) \(data.count) bytes")
            return folder.appendingPathComponent(name)
        }
    }

    private struct NoPicker: ImagePicker {
        func pickImage() async -> URL? {
            print("PREVIEW_PICK_IMAGE")
            return nil
        }
    }

    private final class MemoryFlags: FlagStore {
        var values: [String: Any] = [:]
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
        func set(_ value: Int, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func hasValue(forKey key: String) -> Bool { values[key] != nil }
    }

    /// Registers in memory only.
    private final class PreviewLoginItemService: LoginItemService {
        private(set) var status: SMAppService.Status = .notRegistered
        func register() throws { status = .enabled }
        func unregister() throws { status = .notRegistered }
        func openSystemSettings() { print("PREVIEW_OPEN_LOGIN_ITEMS") }
    }

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(at: Self.suiteDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: Self.suite)!
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-preview-\(UUID().uuidString)", isDirectory: true))
        preferences = Preferences(defaults: defaults)
        preferences.sameOnAllDisplays = false
        loginItem = LoginItem(flags: MemoryFlags(), service: PreviewLoginItemService())
        model = AppModel(
            preferences: preferences, license: license, paths: paths, desktop: desktop,
            exporter: NoExport(), imagePicker: NoPicker(), displays: { PreviewHarness.displays }
        )
        model.setExportReveal { print("PREVIEW_REVEAL \($0.path)") }
        model.accentColor = { RGBAColor(hex: 0x304BFF) }
        model.copyToPasteboard = { print("PREVIEW_PASTEBOARD \($0.count) characters") }
        // Loading the documents below must reach no desktop, not even the
        // recording one: the count printed at the end stays zero.
        model.appliesLive = false
        AppResources.registerFonts()
    }

    /// The four desktops the column is drawn over, so the PNGs prove its
    /// labels read on any of them: a saturated pink/orange mesh, a neutral
    /// grey, near-black, near-white.
    static let backdrops: [(String, Wallpaper)] = [
        ("mesh", Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: [RGBAColor(hex: 0xFF3D8A), RGBAColor(hex: 0xFF7A2F), RGBAColor(hex: 0xFFB48A), RGBAColor(hex: 0xF3A0DC)], jitter: 0.6, softness: 0.6)), seed: 11, grain: 0.05)),
        ("grey", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x858585))), seed: 1)),
        ("black", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x0A0A0A))), seed: 1)),
        ("white", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0xF6F6F6))), seed: 1)),
    ]

    /// Every surface in both appearances; true when every PNG was written.
    func run() async -> Bool {
        defer {
            defaults.removePersistentDomain(forName: Self.suite)
            defaults.removeSuite(named: Self.suite)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: Self.suiteDirectory)
            try? FileManager.default.removeItem(at: paths.root)
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("PREVIEW_FAILED \(error)")
            return false
        }
        var failures = 0
        // A source for pixelize: a render of the starter, imported.
        let source = WallpaperRenderer().render(Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: Palettes.all[1])), seed: 3), size: PixelSize(width: 640, height: 400))
        let sourceReference = try? model.imports.importImage(data: source.pngData() ?? Data())
        // The desktops of the drawn stages.
        let stageSize = PixelSize(width: 1512, height: 982)
        let backdrops = Self.backdrops.map { ($0.0, WallpaperRenderer().render($0.1, size: stageSize).cgImage) }
        let mesh = backdrops[0].1

        let documents: [(String, Wallpaper)] = [
            ("mesh", Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: Palettes.preset(named: "Sea")?.tones ?? Palettes.all[1], jitter: 0.6, softness: 0.5)), seed: 42, grain: 0.08, pair: .lightDark, composition: .emerge)),
            ("field", .starter),
            ("relief", TasteSet.recipes.first { $0.wallpaper.generator.fieldFamily == .relief }?.wallpaper ?? .starter),
            ("pattern", Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: RGBAColor(hex: 0xFFB48A), background: RGBAColor(hex: 0x4A2114), scale: 64)), seed: 7, grain: 0.1, composition: .contours)),
            ("solid", Wallpaper.trueBlack),
            ("pixelize", Wallpaper(generator: .pixelize(PixelizeParameters(source: sourceReference, blockSize: 24, paletteSize: 6, fit: .fill, background: .black)), seed: 5)),
            ("dither", Wallpaper(generator: .dither(DitherParameters(source: sourceReference, mode: .floydSteinberg, cell: 3, ink: RGBAColor(hex: 0x141414), paper: RGBAColor(hex: 0xFFF1EA))), seed: 5, finish: Finish(duotone: Duotone(shadow: RGBAColor(hex: 0x242B55), highlight: RGBAColor(hex: 0xFFD528))), pair: .timeOfDay(frames: 8))),
        ]
        // The mesh is "on the desktop" of the built-in display, and in the history.
        try? model.applied.update { $0.set(documents[0].1, for: 1); $0.lastApplied = Date() }
        try? model.history.record(documents[2].1, at: Date().addingTimeInterval(-3600))
        try? model.history.record(documents[0].1)
        model.reloadAppliedState()
        model.targetDisplay = 1
        model.refreshDisplays()
        _ = try? model.favorites.add(documents[1].1, named: "Morning starter")
        _ = try? model.favorites.add(documents[3].1)
        preferences.pins = [.palette, .jitter]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let scheme: ColorScheme = appearance == .aqua ? .light : .dark
            model.systemAppearance = { appearance == .aqua ? .light : .dark }
            model.editingSide = nil

            // The Parameters section for the mesh over every backdrop at every width.
            model.load(documents[0].1)
            model.panelSection = .parameters
            await waitForPreview()
            for (backdropName, backdrop) in backdrops {
                for width in PanelWidth.allCases {
                    let stage = notchStage(backdrop: backdrop, width: width)
                    if await !write(stage, scheme: scheme, appearance: appearance, to: "panel-\(backdropName)-\(width.rawValue)-\(suffix).png") { failures += 1 }
                }
            }
            // Every section, on the mesh backdrop at the regular width.
            for section in PanelSection.allCases {
                model.panelSection = section
                let stage = notchStage(backdrop: mesh)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "section-\(section.rawValue)-\(suffix).png") { failures += 1 }
            }
            // The Parameters section for every generator.
            model.panelSection = .parameters
            for (name, document) in documents.dropFirst() {
                model.load(document)
                await waitForPreview()
                let stage = notchStage(backdrop: mesh)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "parameters-\(name)-\(suffix).png") { failures += 1 }
            }
            // The dark side of the mesh, edited, under Effects.
            model.load(documents[0].1)
            model.editingSide = .dark
            model.materializeDarkSide()
            model.panelSection = .effects
            await waitForPreview()
            if await !write(notchStage(backdrop: mesh), scheme: scheme, appearance: appearance, to: "effects-darkside-\(suffix).png") { failures += 1 }
            model.editingSide = nil
            model.load(documents[0].1)
            model.panelSection = .library
            await waitForPreview()
            // Opened from the menu-bar item: under the item, centered on it,
            // on the notched display and on one without a notch; the column
            // as tall as its content (the Library, here, reaches the cap).
            let builtIn = FakeScreen.notched14
            if await !write(builtIn.stage(backdrop: mesh, column: column(on: builtIn, anchor: .statusItem(builtIn.item))), scheme: scheme, appearance: appearance, to: "menubar-notch-1512-\(suffix).png") { failures += 1 }
            let external = PreviewHarness.displays[1]
            model.targetDisplay = external.id
            await waitForPreview()
            let plain = FakeScreen.plain(width: 1440, height: 900)
            if await !write(plain.stage(backdrop: backdrops[3].1, column: column(on: plain, anchor: .statusItem(plain.item))), scheme: scheme, appearance: appearance, to: "menubar-plain-1440-\(suffix).png") { failures += 1 }
            // A short section on the plain display: the column ends with its content.
            model.panelSection = .export
            if await !write(plain.stage(backdrop: backdrops[3].1, column: column(on: plain, anchor: .statusItem(plain.item))), scheme: scheme, appearance: appearance, to: "menubar-plain-1440-export-\(suffix).png") { failures += 1 }
            model.panelSection = .library
            // A small display: the column capped to the visible frame, the
            // Library scrolled inside it while the footer stays.
            let small = FakeScreen.plain(width: 1280, height: 800)
            // Ten more recipes, so the library outgrows the column.
            let extras = TasteSet.recipes.prefix(10).compactMap { try? model.favorites.add($0.wallpaper, named: $0.name) }
            await waitForPreview()
            if await !write(small.stage(backdrop: backdrops[1].1, column: column(on: small, anchor: .statusItem(small.item), scrolled: 300)), scheme: scheme, appearance: appearance, to: "small-1280-scrolled-\(suffix).png") { failures += 1 }
            for extra in extras { model.removeFavorite(extra) }
            // The first-run glow under the notch, the pointer near it.
            if await !write(builtIn.stage(backdrop: mesh, column: nil, glow: true), scheme: scheme, appearance: appearance, to: "glow-hint-\(suffix).png") { failures += 1 }
            // The setup guide's panel step, with and without a notch.
            for hasNotch in [true, false] {
                let flags = MemoryFlags()
                OnboardingLaunch.markReached(.panel, store: flags)
                let guide = OnboardingModel(loginItem: loginItem, license: license, defaults: flags, hasNotch: { hasNotch }, shortcut: { Hotkey.default.displayString })
                if await !write(OnboardingView(model: guide), scheme: scheme, appearance: appearance, to: "guide-panel-\(hasNotch ? "notch" : "plain")-\(suffix).png") { failures += 1 }
            }
            model.targetDisplay = 1
            await waitForPreview()
            // Restricted: the license card in the section's place.
            license.bind(
                access: { false }, state: { .trialEnded }, restriction: { .trialEndedSample },
                badge: { LicenseBadge.label(for: .trialEnded, appName: Licensing.appName) }, canBuy: true
            )
            model.panelSection = .generators
            // With the pill in the header, as the licensing wiring fills the seam.
            let restricted = notchStage(backdrop: mesh, header: AnyView(LicensePillHeader(license: license)))
            if await !write(restricted, scheme: scheme, appearance: appearance, to: "panel-restricted-\(suffix).png") { failures += 1 }
            license.bind(access: { true }, restriction: { nil }, canBuy: false)
            model.panelSection = .library
            let settings = SettingsView(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, diagnostics: { "" })
                .background(Brand.canvas)
            if await !write(settings, scheme: scheme, appearance: appearance, to: "settings-\(suffix).png") { failures += 1 }
        }
        print("PREVIEW_DESKTOP_CALLS \(desktop.calls.count)")
        print("PREVIEW_RENDERED \(outputDirectory.path)")
        return failures == 0
    }

    /// The built-in display with the column dropping from its notch, as
    /// tall as its content up to the cap.
    private func notchStage(backdrop: CGImage?, width: PanelWidth = .regular, header: AnyView? = nil) -> some View {
        let screen = FakeScreen.notched14
        return screen.stage(backdrop: backdrop, column: column(on: screen, anchor: .notch(screen.notch!), width: width, header: header))
    }

    /// The column placed on a pretend display by the real geometry: its
    /// natural height measured off-screen, the frame from
    /// `NotchGeometry.panelFrame`, and, for the harness's renderer, how far
    /// the section is shown scrolled.
    private func column(on screen: FakeScreen, anchor: PanelAnchor, width: PanelWidth = .regular, header: AnyView? = nil, scrolled: CGFloat = 0) -> PlacedColumn {
        let points = PanelMetrics.width(for: width)
        var content = PanelContent(model: model, width: points, anchoredToNotch: anchor.isNotch, header: header, showSettings: {}, quit: {})
        let natural = PanelMetrics.naturalHeight(of: content)
        let frame = NotchGeometry.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, anchor: anchor, width: points, contentHeight: natural)
        content.height = frame.height
        return PlacedColumn(content: content, frame: frame, shade: NotchGeometry.menuBarShadeFrame(screenFrame: screen.frame, anchor: anchor, panelFrame: frame), scrolled: scrolled)
    }

    /// The model renders previews off the main actor; the stage waits for
    /// the draft's own, on the shown side.
    private func waitForPreview() async {
        for _ in 0..<300 where model.previewWallpaper != model.draft || model.previewSide != model.shownSide {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The lists' thumbnails: `ImageRenderer` runs no tasks, so they are rendered first.
        await model.prepareThumbnails(for: model.favoriteList.map(\.wallpaper) + model.historyList.map(\.wallpaper))
    }

    /// Draws the view with `ImageRenderer`, no window: the shared Mac's
    /// display may be asleep and locked, where the window server composites
    /// nothing. Materials and AppKit-backed views cannot be drawn this way,
    /// so the panel's glass and the hotkey field draw flat stand-ins under
    /// `previewRendering`; everything else is the real view.
    private func write(_ view: some View, scheme: ColorScheme, appearance: NSAppearance.Name, to name: String) async -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.previewRendering, true))
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image else {
            print("PREVIEW_CAPTURE_FAILED \(name)")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: outputDirectory.appendingPathComponent(name))
            print("PREVIEW_WROTE \(name) \(image.width)x\(image.height)")
            return true
        } catch {
            print("PREVIEW_WRITE_FAILED \(name) \(error)")
            return false
        }
    }
}

/// The column with its place on a pretend display, in the display's
/// AppKit coordinates.
struct PlacedColumn {
    let content: PanelContent
    let frame: CGRect
    /// The menu-bar shade over a notch-anchored column.
    let shade: CGRect?
    /// How far the section is shown scrolled.
    let scrolled: CGFloat
}

/// A pretend display for the harness: its frame and visible frame as
/// `NSScreen` would report them (AppKit coordinates), its notch and the
/// menu-bar item's frame. No Dock: the visible frame is the screen less
/// the menu bar.
struct FakeScreen {
    let frame: CGRect
    let menuBarHeight: CGFloat
    let notch: CGRect?
    /// The macPaper item, 140 points from the right edge.
    let item: CGRect

    var visibleFrame: CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - menuBarHeight) }

    /// A 14" MacBook Pro: 1512×982, a 37-point menu bar, a 252-point notch.
    static let notched14 = FakeScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), menuBarHeight: 37,
        notch: CGRect(x: 630, y: 945, width: 252, height: 37), item: CGRect(x: 1512 - 140, y: 982 - 30, width: 28, height: 22)
    )

    /// A display without a notch and a 24-point menu bar.
    static func plain(width: CGFloat, height: CGFloat) -> FakeScreen {
        FakeScreen(frame: CGRect(x: 0, y: 0, width: width, height: height), menuBarHeight: 24, notch: nil, item: CGRect(x: width - 140, y: height - 23, width: 28, height: 22))
    }

    /// The display drawn over a desktop: the menu bar (its notch, the
    /// item), the column where the geometry puts it, the shade over the
    /// menu-bar row for a notch-anchored column, and, for the hint, the
    /// glow under the notch with the pointer near it.
    func stage(backdrop: CGImage?, column: PlacedColumn?, glow: Bool = false) -> some View {
        DisplayStage(screen: self, backdrop: backdrop, column: column, glow: glow)
    }
}

/// What the real display looks like with the column in place: drawn to
/// the screen's size, top-left origin, from the AppKit frames.
private struct DisplayStage: View {
    let screen: FakeScreen
    let backdrop: CGImage?
    let column: PlacedColumn?
    let glow: Bool

    /// AppKit to the stage's top-left coordinates.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    var body: some View {
        let notched = screen.notch != nil
        ZStack(alignment: .topLeading) {
            if let backdrop {
                Image(decorative: backdrop, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Brand.surface
            }
            // The menu-bar row: translucent, dark over a wallpaper with a
            // notch (the built-in display), light on the plain one.
            Rectangle().fill(notched ? Color.black.opacity(0.12) : Color.white.opacity(0.7)).frame(height: screen.menuBarHeight)
            if let column, let shade = column.shade {
                MenuBarShade().frame(width: shade.width, height: shade.height).offset(x: flipped(shade).minX, y: flipped(shade).minY)
            }
            HStack(spacing: 14) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("Finder").font(.system(size: 13, weight: .semibold))
                Text("File").font(.system(size: 13))
                Text("Edit").font(.system(size: 13))
                Text("View").font(.system(size: 13))
                Spacer()
                Image(systemName: "wifi").font(.system(size: 13))
                Text("Tue 9:41").font(.system(size: 13))
            }
            .foregroundStyle(notched ? .white : .black)
            .padding(.horizontal, 16)
            .padding(.trailing, 130)
            .frame(height: screen.menuBarHeight)
            // The item, lit while the column hangs from it.
            let item = flipped(screen.item)
            Image(nsImage: AppResources.menuBarImage()).renderingMode(.template)
                .foregroundStyle(notched ? .white : .black)
                .frame(width: item.width, height: item.height)
                .background((notched ? Color.white : Color.black).opacity(column?.content.anchoredToNotch == false ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 4))
                .offset(x: item.minX, y: item.minY)
            if let notch = screen.notch {
                let rect = flipped(notch)
                if glow {
                    let frame = flipped(NotchGeometry.hintGlowFrame(screenFrame: screen.frame, notch: notch))
                    NotchGlow().frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                }
                Rectangle().fill(Color.black).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                if glow {
                    // The pointer, 60 points under the notch's edge: within reach.
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                        .offset(x: rect.midX + 40, y: rect.maxY + 60)
                }
            }
            if let column {
                let frame = flipped(column.frame)
                column.content
                    .environment(\.previewScrollOffset, column.scrolled)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: screen.frame.width, height: screen.frame.height, alignment: .topLeading)
        .clipped()
    }
}
#endif
