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

    /// Picks and saves nothing on its own; a test sets `pickURL`/`saveURL`
    /// to the file it wants `importRecipe()`/`exportRecipe()` to use.
    final class FakeRecipeDialog: RecipeDialog {
        var pickURL: URL?
        var saveURL: URL?
        func pickRecipeFile() async -> URL? { pickURL }
        func saveRecipeFile(named name: String) async -> URL? { saveURL }
    }

    @MainActor
    struct Harness {
        let directory: URL
        let temporaryDefaults: TemporaryDefaults
        var defaults: UserDefaults { temporaryDefaults.defaults }
        let preferences: Preferences
        let license = LicenseStatus()
        let desktop = RecordingApplier()
        let exporter = MemoryExporter()
        let picker = FixedPicker()
        let recipeDialog = FakeRecipeDialog()
        let model: AppModel
        static let displays = [
            DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 32, height: 20), scale: 2, notchWidth: 10, isMain: true),
            DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 40, height: 20), scale: 1),
        ]

        /// `directory` lets two Harnesses share the same on-disk stores (to
        /// test what a second launch sees); `starterRecipes` seeds the
        /// library the way a fresh install's taste set does.
        init(directory: URL? = nil, starterRecipes: [Recipe] = []) {
            self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-app-tests-\(UUID().uuidString)", isDirectory: true)
            temporaryDefaults = try! TemporaryDefaults()
            preferences = Preferences(defaults: temporaryDefaults.defaults)
            model = AppModel(
                preferences: preferences, license: license, paths: AppPaths(root: self.directory), desktop: desktop,
                exporter: exporter, imagePicker: picker, recipeDialog: recipeDialog, starterRecipes: starterRecipes, displays: { Harness.displays }
            )
            model.setExportReveal { _ in }
            // The explicit actions are under test here; live apply has its
            // own suite (LiveApplyTests).
            model.appliesLive = false
            // Deterministic: the light side, a fixed accent, no pasteboard.
            model.systemAppearance = { .light }
            model.accentColor = { RGBAColor(hex: 0x304BFF) }
            model.copyToPasteboard = { _ in }
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
            temporaryDefaults.remove()
        }

        /// The apply runs on a detached task; wait for it.
        func settle() async {
            // A pixel-field document renders slower than a gradient in a
            // debug build: up to thirty seconds, out as soon as it is done.
            for _ in 0..<3000 where model.isApplying || model.isExporting {
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
        h.model.load(.starter.reseeded(2))
        h.model.apply(ApplyTarget(scope: .allDisplays))
        await h.settle()
        #expect(h.desktop.calls.count == 3)
        #expect(h.model.displaysDiffer == false)
        h.preferences.sameOnAllDisplays = true
        h.model.load(.starter.reseeded(3))
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
        h.model.load(before.reseeded(99))
        let edited = h.model.draft
        h.model.scheduledShuffle()
        await h.settle()
        #expect(h.model.draft == edited)
        #expect(h.model.appliedState.wallpaper(for: 1) != edited)
        // A draft that is the applied one follows the scheduled shuffle.
        h.model.load(h.model.appliedState.wallpaper(for: 1)!)
        h.model.scheduledShuffle()
        await h.settle()
        #expect(h.model.draft == h.model.appliedState.wallpaper(for: 1))
    }

    @Test("Shuffle finds nothing better when the pins can't be satisfied: no desktop calls, the draft and applied state untouched, the status names it")
    func shuffleNothingBetter() async {
        let h = Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        // A pinned generator the gate always refuses (a bare gradient):
        // every attempt on every display fails `.bare`, so the plan comes
        // back empty and shuffle() must not fall back to an unvalidated
        // candidate (fix round 1, P0-1). Pins are the user's own setting
        // (Preferences.pins), not carried on the Wallpaper literal — `load`
        // always mirrors the current preference onto the draft.
        h.preferences.pins = [.generator]
        let bare = Wallpaper(generator: .gradient(GradientParameters(kind: .linear, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1)
        h.model.load(bare)
        let before = h.model.draft
        h.model.shuffle()
        await h.settle()
        #expect(h.desktop.calls.isEmpty)
        #expect(h.model.draft == before)
        #expect(h.model.appliedState.byDisplay.isEmpty)
        #expect(h.model.status?.text == Shuffle.nothingBetterMessage)
        #expect(h.model.status?.tone == .error)
    }

    @Test("Favorites toggle by document and reload from disk")
    func favorites() {
        let h = Harness()
        defer { h.tearDown() }
        h.model.toggleFavorite()
        #expect(h.model.isFavorite)
        #expect(h.model.favoriteList.map(\.wallpaper) == [.starter])
        h.model.load(.starter.reseeded(5))
        #expect(!h.model.isFavorite)
        h.model.load(h.model.favoriteList[0])
        #expect(h.model.draft == .starter && h.model.isFavorite)
        h.model.toggleFavorite()
        #expect(!h.model.isFavorite && h.model.favoriteList.isEmpty)
        #expect(FavoritesStore(fileURL: AppPaths(root: h.directory).favorites).all.isEmpty)
    }

    @Test("Pin toggling survives edit")
    func pinning() {
        let h = Harness()
        defer { h.tearDown() }
        #expect(h.model.pinnedKeys.isEmpty)
        h.model.pin(.seed)
        h.model.pin(.palette)
        #expect(h.model.isPinned(.seed) && h.model.isPinned(.palette) && !h.model.isPinned(.family))
        h.model.togglePin(.seed)
        #expect(!h.model.isPinned(.seed), "toggle off")
        h.model.togglePin(.family)
        #expect(h.model.isPinned(.family), "toggle on")
        // An edit changes the document but leaves the pins as they are.
        h.model.reseed()
        #expect(h.model.pinnedKeys == [.palette, .family])
        h.model.unpin(.palette)
        #expect(h.model.pinnedKeys == [.family])
        // Pinning is not generating: it works while restricted.
        h.license.bind(access: { false }, restriction: { .trialEndedSample }, canBuy: true)
        h.model.pin(.seed)
        #expect(h.model.isPinned(.seed), "pinning bypasses the license gate")
    }

    @Test("importRecipe(at:) adds to the library and loads it; junk and an oversized file are refused")
    func importRecipeAt() throws {
        let h = Harness()
        defer { h.tearDown() }
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        let recipe = RecipeDocument(name: "Imported look", wallpaper: TasteSet.recipes[4].wallpaper)
        let good = h.directory.appendingPathComponent("good.macpaper")
        try recipe.fileData().write(to: good)
        h.model.importRecipe(at: good)
        #expect(h.model.draft == recipe.wallpaper)
        #expect(h.model.favoriteList.contains { $0.wallpaper == recipe.wallpaper && $0.name == "Imported look" })
        #expect(h.model.status?.text == "Imported “Imported look”.")
        // Junk: decodes as neither a bare document nor a recipe.
        let before = h.model.draft
        let junk = h.directory.appendingPathComponent("junk.macpaper")
        try Data("not a recipe".utf8).write(to: junk)
        h.model.importRecipe(at: junk)
        #expect(h.model.status?.tone == .error)
        #expect(h.model.draft == before, "kept")
        // Oversized: refused by size before it is even parsed.
        let oversized = h.directory.appendingPathComponent("big.macpaper")
        try Data(repeating: 0x20, count: ShareCode.maxDocumentBytes + 1).write(to: oversized)
        h.model.importRecipe(at: oversized)
        #expect(h.model.status?.tone == .error)
        #expect(h.model.draft == before, "kept")
    }

    @Test("exportRecipe() writes the draft through the recipe dialog")
    func exportRecipeFile() async throws {
        let h = Harness()
        defer { h.tearDown() }
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        let destination = h.directory.appendingPathComponent("chosen-name.macpaper")
        h.recipeDialog.saveURL = destination
        h.model.saveRecipe(named: "My export")
        await h.model.exportRecipe()
        let written = try RecipeDocument.decode(try Data(contentsOf: destination))
        #expect(written.wallpaper == h.model.draft)
        #expect(written.name == "My export")
        #expect(h.model.status?.text == "Exported chosen-name.macpaper.")
        // Nothing picked: nothing written, nothing said.
        h.recipeDialog.saveURL = nil
        h.model.clearStatus()
        await h.model.exportRecipe()
        #expect(h.model.status == nil)
    }

    @Test("shareLink() copies a macpaper://s/ code that decodes back to the draft, named like the library entry")
    func shareLinkCode() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.model.saveRecipe(named: "Shared look")
        var copied: String?
        h.model.copyToPasteboard = { copied = $0 }
        h.model.shareLink()
        let text = try #require(copied)
        #expect(text.hasPrefix("macpaper://s/"))
        let document = try ShareCode.decode(url: try #require(URL(string: text)))
        #expect(document.wallpaper == h.model.draft)
        #expect(document.name == "Shared look")
        #expect(h.model.status?.text == "Link copied.")
    }

    @Test("starterRecipes seeds the library only on an absent favorites file")
    func starterRecipesSeeding() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-app-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let starters = [TasteSet.recipes[8], TasteSet.recipes[9]]
        let fresh = Harness(directory: directory, starterRecipes: starters)
        #expect(fresh.model.favoriteList.map(\.id) == starters.map(\.id), "an absent file takes the starters")
        // Nothing is written to disk until the library changes.
        #expect(!FileManager.default.fileExists(atPath: AppPaths(root: directory).favorites.path))
        fresh.model.toggleFavorite()
        fresh.model.toggleFavorite()
        #expect(FileManager.default.fileExists(atPath: AppPaths(root: directory).favorites.path))
        // A second launch over the same, now-present file ignores different starters.
        let relaunched = Harness(directory: directory, starterRecipes: [TasteSet.recipes[0]])
        #expect(relaunched.model.favoriteList.map(\.id) == starters.map(\.id), "a present file takes no starters")
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
        #expect(h.exporter.exported[0].0 == WallpaperExport.fileName(for: .starter, format: .png))
        let decoded = try #require(Raster.decode(h.exporter.exported[0].1))
        #expect(decoded.size == PixelSize(width: 40, height: 20))
        h.model.export(.svg)
        await h.settle()
        #expect(h.exporter.exported[1].0 == WallpaperExport.fileName(for: .starter, format: .svg))
        #expect(String(decoding: h.exporter.exported[1].1, as: UTF8.self).contains("<image "), "a pixel field embeds its render")
        #expect(h.model.status?.text == "Exported \(WallpaperExport.fileName(for: .starter, format: .svg)).")
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
