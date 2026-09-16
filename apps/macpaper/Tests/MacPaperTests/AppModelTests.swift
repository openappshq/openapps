import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// The model over temporary stores, a recording desktop applier, fake
/// displays, an exporter that keeps the bytes and a picker that picks a
/// prepared file. No window, no status item, no real desktop.
@MainActor
struct AppModelTests {
    final class MemoryExporter: FileExporter {
        var exported: [(String, Data)] = []
        var refuse = false
        func export(_ data: Data, named name: String, to folder: URL, mayWrite: @escaping @MainActor () -> Bool) async throws -> URL {
            if refuse { throw CocoaError(.fileWriteNoPermission) }
            guard mayWrite() else { throw AppModel.Refused() }
            exported.append((name, data))
            return folder.appendingPathComponent(name)
        }
    }

    final class FixedPicker: ImagePicker {
        var url: URL?
        func pickImage() async -> URL? { url }
    }

    @MainActor
    struct Harness {
        let directory: URL
        let defaults: UserDefaults
        let preferences: Preferences
        let license = LicenseStatus()
        let desktop = RecordingApplier()
        let exporter = MemoryExporter()
        let picker = FixedPicker()
        let model: AppModel
        static let displays = [
            DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 32, height: 20), scale: 2, notchWidth: 10, isMain: true),
            DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 40, height: 20), scale: 1),
        ]

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-app-tests-\(UUID().uuidString)", isDirectory: true)
            let suite = "space.openapps.macpaper.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            preferences = Preferences(defaults: defaults)
            model = AppModel(
                preferences: preferences, license: license, paths: AppPaths(root: directory), desktop: desktop,
                exporter: exporter, imagePicker: picker, displays: { Harness.displays }
            )
            model.setExportReveal { _ in }
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// The apply runs on a detached task; wait for it.
        func settle() async {
            for _ in 0..<200 where model.isApplying || model.isExporting {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test("A fresh model starts on the starter document, previewing the main display")
    func fresh() async {
        let h = Harness()
        defer { h.tearDown() }
        #expect(h.model.draft == .starter)
        #expect(h.model.currentDisplay?.id == 1)
        #expect(h.model.previewSize == PixelSize(width: 64, height: 40))
        #expect(h.model.appliedState.byDisplay.isEmpty)
        #expect(!h.model.isFavorite)
        for _ in 0..<200 where h.model.previewWallpaper != .starter { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(h.model.previewWallpaper == .starter)
        #expect(h.model.preview?.width == 64)
    }

    @Test("Apply renders per display, records the documents and the last apply, and same-on-all overrides the scope")
    func apply() async throws {
        let h = Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = false
        h.model.targetDisplay = 2
        h.model.apply()
        await h.settle()
        #expect(h.desktop.calls.map(\.display) == [2])
        #expect(h.model.appliedState.wallpaper(for: 2) == .starter)
        #expect(h.model.appliedState.wallpaper(for: 1) == nil)
        #expect(h.model.appliedState.lastApplied != nil)
        #expect(h.model.currentApplied == .starter)
        #expect(h.model.status?.text == "Applied.")
        let raster = try #require(Raster.decode(try Data(contentsOf: h.desktop.calls[0].url)))
        #expect(raster.size == PixelSize(width: 40, height: 20))
        h.model.draft = .starter.reseeded(2)
        h.model.apply(.allDisplays)
        await h.settle()
        #expect(h.desktop.calls.count == 3)
        #expect(h.model.displaysDiffer == false)
        h.preferences.sameOnAllDisplays = true
        h.model.draft = .starter.reseeded(3)
        h.model.apply()
        await h.settle()
        #expect(Set(h.desktop.calls.suffix(2).map(\.display)) == [1, 2])
        #expect(h.model.status?.text == "Applied to 2 displays.")
        // The applied file survives a relaunch.
        let reloaded = AppliedStore(fileURL: AppPaths(root: h.directory).applied).current
        #expect(reloaded.wallpaper(for: 1) == Wallpaper.starter.reseeded(3))
    }

    @Test("A refused display is reported and the others are recorded")
    func applyFailure() async {
        let h = Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        struct Refused: Error, LocalizedError { var errorDescription: String? { "no" } }
        h.desktop.failure = Refused()
        h.model.apply()
        await h.settle()
        #expect(h.model.status?.tone == .error)
        #expect(h.model.appliedState.byDisplay.isEmpty)
        #expect(!h.model.isApplying)
    }

    @Test("Shuffle applies a random document and shows it; the scheduled shuffle leaves an edited draft alone")
    func shuffle() async {
        let h = Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        let before = h.model.draft
        h.model.shuffle()
        await h.settle()
        #expect(h.model.draft != before)
        #expect(h.model.appliedState.wallpaper(for: 1) == h.model.draft)
        #expect(h.model.appliedState.wallpaper(for: 2) == h.model.draft)
        // Editing the draft, then a scheduled shuffle: the desktop changes, the draft stays.
        h.model.draft = before.reseeded(99)
        let edited = h.model.draft
        h.model.scheduledShuffle()
        await h.settle()
        #expect(h.model.draft == edited)
        #expect(h.model.appliedState.wallpaper(for: 1) != edited)
        // A draft that is the applied one follows the scheduled shuffle.
        h.model.draft = h.model.appliedState.wallpaper(for: 1)!
        h.model.scheduledShuffle()
        await h.settle()
        #expect(h.model.draft == h.model.appliedState.wallpaper(for: 1))
    }

    @Test("Favorites toggle by document and reload from disk")
    func favorites() {
        let h = Harness()
        defer { h.tearDown() }
        h.model.toggleFavorite()
        #expect(h.model.isFavorite)
        #expect(h.model.favoriteList.map(\.wallpaper) == [.starter])
        h.model.draft = .starter.reseeded(5)
        #expect(!h.model.isFavorite)
        h.model.load(h.model.favoriteList[0])
        #expect(h.model.draft == .starter && h.model.isFavorite)
        h.model.toggleFavorite()
        #expect(!h.model.isFavorite && h.model.favoriteList.isEmpty)
        #expect(FavoritesStore(fileURL: AppPaths(root: h.directory).favorites).all.isEmpty)
    }

    @Test("Switching generators carries colors; reseed and typed seeds")
    func editing() {
        let h = Harness()
        defer { h.tearDown() }
        let colors = h.model.draft.generator.colors
        h.model.generatorKind = .mesh
        #expect(h.model.draft.generator.kind == .mesh)
        #expect(h.model.draft.generator.colors == colors)
        h.model.generatorKind = .mesh
        #expect(h.model.draft.generator.colors == colors, "no change on the same kind")
        let seed = h.model.draft.seed
        h.model.reseed()
        #expect(h.model.draft.seed != seed)
        #expect(h.model.setSeed(" 12345 ") == .set)
        #expect(h.model.draft.seedText == "12345")
        #expect(h.model.setSeed("twelve") == .notANumber)
        #expect(h.model.draft.seedText == "12345")
    }

    @Test("Importing an image switches to pixelize with the reference; junk is reported")
    func importing() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let image = h.directory.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try WallpaperRenderer().render(.starter, size: PixelSize(width: 8, height: 8)).pngData()!.write(to: image)
        h.picker.url = image
        await h.model.importImage()
        guard case .pixelize(let p) = h.model.draft.generator else {
            Issue.record("not pixelize")
            return
        }
        #expect(p.source != nil)
        #expect(h.model.imports.raster(for: p.source!) != nil)
        #expect(h.model.status?.text == "Imported source.png.")
        let junk = h.directory.appendingPathComponent("junk.png")
        try Data("nope".utf8).write(to: junk)
        await h.model.importImage(at: junk)
        #expect(h.model.status?.tone == .error)
        #expect(h.model.draft.generator == .pixelize(p), "kept")
        // Nothing picked: nothing changes.
        h.picker.url = nil
        await h.model.importImage()
        #expect(h.model.draft.generator == .pixelize(p))
    }

    @Test("Export renders at the display's size, names the file, and reports a refusal")
    func exporting() async throws {
        let h = Harness()
        defer { h.tearDown() }
        h.model.targetDisplay = 2
        h.model.export(.png)
        await h.settle()
        #expect(h.exporter.exported.count == 1)
        #expect(h.exporter.exported[0].0 == "macPaper-gradient-20260916.png")
        let decoded = try #require(Raster.decode(h.exporter.exported[0].1))
        #expect(decoded.size == PixelSize(width: 40, height: 20))
        h.model.export(.svg)
        await h.settle()
        #expect(h.exporter.exported[1].0 == "macPaper-gradient-20260916.svg")
        #expect(String(decoding: h.exporter.exported[1].1, as: UTF8.self).contains("<linearGradient"))
        #expect(h.model.status?.text == "Exported macPaper-gradient-20260916.svg.")
        h.exporter.refuse = true
        h.model.export(.png)
        await h.settle()
        #expect(h.model.status?.tone == .error)
    }

    @Test("While restricted, apply, shuffle and export do nothing")
    func restricted() async {
        let h = Harness()
        defer { h.tearDown() }
        h.license.bind(access: { false }, restriction: { .trialEndedSample }, canBuy: true)
        #expect(!h.model.canAct)
        h.model.apply()
        h.model.shuffle()
        h.model.scheduledShuffle()
        h.model.export(.png)
        await h.settle()
        #expect(h.desktop.calls.isEmpty && h.exporter.exported.isEmpty)
        #expect(h.model.license.restriction()?.title == "Your free trial has ended")
        h.license.bind(access: { true }, restriction: { nil }, canBuy: false)
        #expect(h.model.canAct)
    }

    @Test("A display that goes away is no longer the target")
    func displays() {
        let h = Harness()
        defer { h.tearDown() }
        h.model.targetDisplay = 2
        #expect(h.model.currentDisplay?.id == 2)
        h.model.targetDisplay = 9
        #expect(h.model.currentDisplay?.id == 1, "unknown: the main display")
        h.model.refreshDisplays()
        #expect(h.model.targetDisplay == nil)
    }

    @Test("Switching the target display re-renders the preview at that display's aspect")
    func targetPreview() async {
        let h = Harness()
        defer { h.tearDown() }
        for _ in 0..<200 where h.model.preview == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(h.model.preview?.width == 64 && h.model.preview?.height == 40, "the 32×20@2 display")
        h.model.targetDisplay = 2
        for _ in 0..<200 where h.model.preview?.width != 40 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(h.model.preview?.width == 40 && h.model.preview?.height == 20, "the 40×20@1 display, same document")
        #expect(h.model.previewWallpaper == h.model.draft)
    }

    @Test("Diagnostics text reads the live objects")
    func diagnostics() {
        let h = Harness()
        defer { h.tearDown() }
        let hotkeys = HotkeyCenter()
        let text = Diagnostics.text(model: h.model, preferences: h.preferences, loginItem: LoginItem(flags: h.defaults, service: InertLoginItemService()), hotkeys: hotkeys)
        #expect(text.hasPrefix("macPaper dev (0)\n"))
        #expect(text.contains("Licensing: \(Licensing.flavourDescription)"))
        #expect(text.contains("- Built-in (1) · 32×20 pt @2x · 64×40 px · notch 10 pt · main"))
        #expect(text.contains("Hotkey: ⌃⌥⌘W"))
        #expect(text.contains("Applied:\n- nothing yet"))
    }
}

/// Never touches `SMAppService`.
final class InertLoginItemService: LoginItemService {
    var status: ServiceManagement.SMAppService.Status = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettings() {}
}

import ServiceManagement
