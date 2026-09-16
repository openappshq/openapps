#if DEBUG
import AppKit
import MacPaperCore
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
    nonisolated static let suite = "space.openapps.macpaper.preview"

    private let outputDirectory: URL
    private let defaults = UserDefaults(suiteName: PreviewHarness.suite)!
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
        func export(_ data: Data, named name: String, to folder: URL) async throws -> URL {
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
        defaults.removePersistentDomain(forName: Self.suite)
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-preview-\(UUID().uuidString)", isDirectory: true))
        preferences = Preferences(defaults: defaults)
        preferences.sameOnAllDisplays = false
        loginItem = LoginItem(flags: MemoryFlags(), service: PreviewLoginItemService())
        model = AppModel(
            preferences: preferences, license: license, paths: paths, desktop: desktop,
            exporter: NoExport(), imagePicker: NoPicker(), displays: { PreviewHarness.displays }
        )
        model.setExportReveal { print("PREVIEW_REVEAL \($0.path)") }
        AppResources.registerFonts()
    }

    /// Every surface in both appearances; true when every PNG was written.
    func run() async -> Bool {
        defer {
            defaults.removePersistentDomain(forName: Self.suite)
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
        // The desktop of the drawn stage.
        let backdrop = WallpaperRenderer().render(Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: Palettes.all[3], jitter: 0.6, softness: 0.6)), seed: 11, grain: 0.05), size: PixelSize(width: 1200, height: 780)).cgImage

        let documents: [(String, Wallpaper)] = [
            ("gradient", .starter),
            ("mesh", Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: Palettes.all[1], jitter: 0.6, softness: 0.5)), seed: 42)),
            ("pattern", Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: RGBAColor(hex: 0xFFB48A), background: RGBAColor(hex: 0x4A2114), scale: 64)), seed: 7, grain: 0.1)),
            ("solid", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x236B48))), seed: 3, grain: 0.3)),
            ("pixelize", Wallpaper(generator: .pixelize(PixelizeParameters(source: sourceReference, blockSize: 24, paletteSize: 6, fit: .fill, background: .black)), seed: 5)),
        ]
        // The mesh is "on the desktop" of the built-in display.
        try? model.applied.update { $0.set(documents[1].1, for: 1); $0.lastApplied = Date() }
        model.reloadAppliedState()
        model.targetDisplay = 1
        model.refreshDisplays()
        _ = try? model.favorites.add(documents[0].1)
        _ = try? model.favorites.add(documents[3].1)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let scheme: ColorScheme = appearance == .aqua ? .light : .dark
            for (name, document) in documents {
                model.draft = document
                await waitForPreview()
                let stage = NotchStage(backdrop: backdrop, content: PanelContent(model: model, width: preferences.width.points, showSettings: {}, quit: {}))
                if await !write(stage, scheme: scheme, appearance: appearance, to: "panel-\(name)-\(suffix).png") { failures += 1 }
            }
            model.draft = documents[0].1
            await waitForPreview()
            if await !write(PopoverStage(model: model), scheme: scheme, appearance: appearance, to: "popover-\(suffix).png") { failures += 1 }
            // Restricted: the license card in the generator's place.
            license.bind(access: { false }, restriction: { .trialEndedSample }, canBuy: true)
            let restricted = NotchStage(backdrop: backdrop, content: PanelContent(model: model, width: preferences.width.points, showSettings: {}, quit: {}))
            if await !write(restricted, scheme: scheme, appearance: appearance, to: "panel-restricted-\(suffix).png") { failures += 1 }
            license.bind(access: { true }, restriction: { nil }, canBuy: false)
            let settings = SettingsView(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, diagnostics: { "" })
                .background(Brand.canvas)
            if await !write(settings, scheme: scheme, appearance: appearance, to: "settings-\(suffix).png") { failures += 1 }
        }
        print("PREVIEW_DESKTOP_CALLS \(desktop.calls.count)")
        print("PREVIEW_RENDERED \(outputDirectory.path)")
        return failures == 0
    }

    /// The model renders previews off the main actor; the stage waits for
    /// the draft's own.
    private func waitForPreview() async {
        for _ in 0..<200 where model.previewWallpaper != model.draft {
            try? await Task.sleep(for: .milliseconds(20))
        }
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

/// A drawn 14" menu bar with its notch over a desktop, the panel hanging
/// from the notch: what the real panel looks like in place.
private struct NotchStage: View {
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
                    Rectangle().fill(Color.black.opacity(0.28)).frame(height: 37)
                    HStack {
                        Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                        Text("Finder").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "wifi").font(.system(size: 13))
                        Text("Tue 9:41").font(.system(size: 13))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    Rectangle().fill(Color.black).frame(width: 252, height: 37)
                }
                content
            }
        }
        .frame(width: 900, height: 700, alignment: .top)
        .clipped()
    }
}

/// The popover as the menu-bar item shows it: on a plain desktop.
private struct PopoverStage: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Brand.surface, Brand.canvas], startPoint: .top, endPoint: .bottom)
            WallpaperPanelView(model: model, showSettings: {}, quit: {})
                .background(Brand.canvas, in: RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous).strokeBorder(Brand.borderSubtle, lineWidth: 1))
                .padding(24)
        }
        .frame(width: PanelMetrics.popoverWidth + 48)
    }
}
#endif
