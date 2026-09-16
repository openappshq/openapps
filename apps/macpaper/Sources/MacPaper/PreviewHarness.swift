#if DEBUG
import AppKit
import MacPaperCore
import OpenAppsLicensing
import ServiceManagement
import SwiftUI

/// Renders the notch panel (on a drawn menu bar with a notch, over a
/// wallpaper), the popover, the restricted state and the settings window
/// to PNGs, in light and dark appearance: `MacPaper --preview <directory>`.
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
            ("mesh", Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: PresetPalettes.named("Sea")?.colors ?? Palettes.all[1], jitter: 0.6, softness: 0.5)), seed: 42, grain: 0.08, pair: .lightDark, composition: .emerge)),
            ("gradient", .starter),
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
        _ = try? model.favorites.add(documents[1].1, name: "Morning starter")
        _ = try? model.favorites.add(documents[3].1)
        preferences.pins = PinnedParameters([.palette, .meshJitter])

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
                    let stage = NotchStage(backdrop: backdrop, content: panelContent(width: width))
                    if await !write(stage, scheme: scheme, appearance: appearance, to: "panel-\(backdropName)-\(width.rawValue)-\(suffix).png") { failures += 1 }
                }
            }
            // Every section, on the mesh backdrop at the regular width.
            for section in PanelSection.allCases {
                model.panelSection = section
                let stage = NotchStage(backdrop: mesh, content: panelContent(width: .regular))
                if await !write(stage, scheme: scheme, appearance: appearance, to: "section-\(section.rawValue)-\(suffix).png") { failures += 1 }
            }
            // The Parameters section for every generator.
            model.panelSection = .parameters
            for (name, document) in documents.dropFirst() {
                model.load(document)
                await waitForPreview()
                let stage = NotchStage(backdrop: mesh, content: panelContent(width: .regular))
                if await !write(stage, scheme: scheme, appearance: appearance, to: "parameters-\(name)-\(suffix).png") { failures += 1 }
            }
            // The dark side of the mesh, edited, under Effects.
            model.load(documents[0].1)
            model.editingSide = .dark
            model.materializeDarkSide()
            model.panelSection = .effects
            await waitForPreview()
            if await !write(NotchStage(backdrop: mesh, content: panelContent(width: .regular)), scheme: scheme, appearance: appearance, to: "effects-darkside-\(suffix).png") { failures += 1 }
            model.editingSide = nil
            model.load(documents[0].1)
            model.panelSection = .library
            await waitForPreview()
            // A display without a notch: the column under the menu-bar item.
            let external = PreviewHarness.displays[1]
            model.targetDisplay = external.id
            await waitForPreview()
            let plain = StatusItemStage(backdrop: backdrops[3].1, content: PanelContent(model: model, width: PanelMetrics.width(for: .regular), height: Self.columnHeight(for: external, notch: false), anchoredToNotch: false, showSettings: {}, quit: {}))
            if await !write(plain, scheme: scheme, appearance: appearance, to: "panel-no-notch-\(suffix).png") { failures += 1 }
            if await !write(PopoverStage(model: model), scheme: scheme, appearance: appearance, to: "popover-\(suffix).png") { failures += 1 }
            model.targetDisplay = 1
            await waitForPreview()
            // Restricted: the license card in the section's place.
            license.bind(
                access: { false }, state: { .trialEnded }, restriction: { .trialEndedSample },
                badge: { LicenseBadge.label(for: .trialEnded, appName: Licensing.appName) }, canBuy: true
            )
            model.panelSection = .generators
            // With the pill in the header, as the licensing wiring fills the seam.
            let restricted = NotchStage(backdrop: mesh, content: panelContent(width: .regular, header: AnyView(LicensePillHeader(license: license))))
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

    /// The column as the notch panel builds it for the built-in display.
    private func panelContent(width: PanelWidth, header: AnyView? = nil) -> PanelContent {
        PanelContent(model: model, width: PanelMetrics.width(for: width), height: Self.columnHeight(for: Self.displays[0], notch: true), anchoredToNotch: true, header: header, showSettings: {}, quit: {})
    }

    /// The column's height on a pretend display: the notched one has a
    /// 37-point notch, the other a 24-point menu bar and the popover gap.
    static func columnHeight(for display: DisplayInfo, notch: Bool) -> CGFloat {
        PanelLayout.columnHeight(screenHeight: display.pointSize.height, topInset: notch ? NotchStage.menuBarHeight : StatusItemStage.menuBarHeight + PanelLayout.popoverGap)
    }

    /// The model renders previews off the main actor; the stage waits for
    /// the draft's own, on the shown side.
    private func waitForPreview() async {
        for _ in 0..<300 where model.previewWallpaper != model.draft || model.previewSide != model.shownSide {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The lists' thumbnails: `ImageRenderer` runs no tasks, so they are rendered first.
        await model.prepareThumbnails(for: model.favoriteList.map(\.wallpaper) + StarterRecipes.all.map(\.wallpaper) + model.historyList.map(\.wallpaper))
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

/// A drawn 14" display (1512×982 points) with its notch and menu bar over
/// a desktop, the column hanging from the notch and shading the menu-bar
/// row beside it: what the real panel looks like in place.
private struct NotchStage: View {
    static let menuBarHeight: CGFloat = 37
    let backdrop: CGImage?
    let content: PanelContent

    var body: some View {
        ZStack(alignment: .top) {
            if let backdrop {
                Image(decorative: backdrop, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Brand.surface
            }
            VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.12)).frame(height: Self.menuBarHeight)
                    // The shade under the menu-bar row, the column's width: the
                    // items above it are untouched.
                    MenuBarShade().frame(width: content.width, height: Self.menuBarHeight)
                    HStack {
                        Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                        Text("Finder").font(.system(size: 13, weight: .semibold))
                        Text("File").font(.system(size: 13))
                        Text("Edit").font(.system(size: 13))
                        Text("View").font(.system(size: 13))
                        Text("Go").font(.system(size: 13))
                        Text("Window").font(.system(size: 13))
                        Spacer()
                        Image(systemName: "wifi").font(.system(size: 13))
                        Text("Tue 9:41").font(.system(size: 13))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    Rectangle().fill(Color.black).frame(width: 252, height: Self.menuBarHeight)
                }
                content
            }
        }
        .frame(width: 1512, height: 982, alignment: .top)
        .clipped()
    }
}

/// A drawn display without a notch: a 24-point menu bar with the item at
/// its right, the column under it as the popover would sit.
private struct StatusItemStage: View {
    static let menuBarHeight: CGFloat = 24
    let backdrop: CGImage?
    let content: PanelContent

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let backdrop {
                Image(decorative: backdrop, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Brand.surface
            }
            VStack(alignment: .trailing, spacing: PanelLayout.popoverGap) {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.7)).frame(height: Self.menuBarHeight)
                    HStack(spacing: 14) {
                        Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                        Text("Finder").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(nsImage: AppResources.menuBarImage()).renderingMode(.template)
                            .frame(width: 22, height: 22)
                            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        Image(systemName: "wifi").font(.system(size: 13))
                        Text("Tue 9:41").font(.system(size: 13))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                }
                // The column's trailing edge on the item's (about 120 points from the right).
                content
                    .padding(.trailing, 120)
            }
        }
        .frame(width: 1512, height: 982, alignment: .top)
        .clipped()
    }
}

/// The popover as the menu-bar item shows it: on a plain desktop.
private struct PopoverStage: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Brand.surface, Brand.canvas], startPoint: .top, endPoint: .bottom)
            WallpaperPanelView(model: model, width: PanelMetrics.popoverWidth, height: 700, showSettings: {}, quit: {})
                .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous).strokeBorder(Brand.Panel.rim, lineWidth: 1))
                .padding(24)
        }
        .frame(width: PanelMetrics.popoverWidth + 48)
    }
}
#endif
