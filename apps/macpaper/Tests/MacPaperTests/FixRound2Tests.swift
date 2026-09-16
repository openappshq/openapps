import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// Review round 2: the theme swap against per-Space displays, the pin
/// against its own races, true black from any state, the clock's timer,
/// and a shuffle with nothing left to pick.
@MainActor
struct FixRound2Tests {
    // MARK: Theme swap

    @Test("A theme change swaps only fallback displays applied to every Space and still showing macPaper's file")
    func themeSwapRespectsSpaces() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = false
        h.desktop.refusesHEIC = true
        h.model.setPair(.lightDark)
        h.model.targetDisplay = 1
        h.model.apply(ApplyTarget(thisSpaceOnly: true))
        await h.settle()
        h.model.targetDisplay = 2
        h.model.apply()
        await h.settle()
        #expect(h.model.appliedState.fallbackDisplayIDs == [1, 2] && h.model.appliedState.perSpaceDisplayIDs == [1])
        // Display 2 shows something else now (another Space, the user, macOS).
        h.desktop.currentOverride[2] = URL(fileURLWithPath: "/System/Library/Desktop Pictures/x.heic")
        let before = h.desktop.calls
        h.model.systemAppearance = { .dark }
        h.model.themeChanged()
        await h.settle()
        #expect(h.desktop.calls == before, "per-Space display 1 and re-pointed display 2: nothing written")
        // Display 2 shows our file again: only it swaps.
        h.desktop.currentOverride[2] = nil
        h.model.themeChanged()
        await h.settle()
        #expect(h.desktop.calls.count == before.count + 1 && h.desktop.calls.last?.display == 2)
        #expect(h.model.appliedState.file(for: 2) == h.desktop.calls.last?.url)
        #expect(h.model.appliedState.perSpaceDisplayIDs == [1], "the per-Space record survives")
    }

    @Test("A theme swap that fails on one display still records the displays it reached")
    func themeSwapPartialFailure() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        h.desktop.refusesHEIC = true
        h.model.setPair(.lightDark)
        h.model.apply()
        await h.settle()
        let old1 = h.model.appliedState.file(for: 1), old2 = h.model.appliedState.file(for: 2)
        h.desktop.failingDisplays = [1]
        h.model.systemAppearance = { .dark }
        h.model.themeChanged()
        await h.settle()
        #expect(h.model.appliedState.file(for: 1) == old1, "display 1 keeps its record")
        #expect(h.model.appliedState.file(for: 2) != old2 && h.model.appliedState.file(for: 2) == h.desktop.calls.last?.url)
        #expect(h.model.appliedState.fallbackDisplayIDs == [1, 2])
    }

    // MARK: The pin

    /// Yields until `condition` holds, or `attempts` runs out (a bounded
    /// wait on a signal, never a clock): `observeChanges`' re-check after a
    /// property changes goes through one `DispatchQueue.main.async` hop
    /// before it re-arms the keeper's debounce, so a scheduled check is not
    /// always visible on the very next line.
    func waitUntil(_ attempts: Int = 200, _ condition: () -> Bool) async {
        for _ in 0..<attempts where !condition() { await Task.yield() }
    }

    @Test("Turning the pin off during its debounce drops the pending re-apply")
    func keeperCancelsOnDisable() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        h.model.apply()
        await h.settle()
        let scheduler = ManualScheduler()
        let keeper = DesktopKeeper(model: h.model, preferences: h.preferences, desktop: h.desktop, scheduler: scheduler)
        h.desktop.currentOverride[1] = URL(fileURLWithPath: "/other.png")
        keeper.check(reason: "test")
        #expect(scheduler.pendingCount == 1)
        h.preferences.keepApplied = false
        await waitUntil { scheduler.pendingCount == 0 }
        #expect(h.desktop.calls.count == 2 && keeper.lastReport == "off")
        // Back on: the pending check runs and re-applies.
        h.preferences.keepApplied = true
        await waitUntil { scheduler.pendingCount == 1 }
        scheduler.fire()
        #expect(h.desktop.calls.count == 3 && h.desktop.calls.last?.display == 1)
    }

    @Test("A check that lands while an apply is in flight waits for it and never re-applies the superseded file")
    func keeperWaitsForApply() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        h.model.apply()
        await h.settle()
        let first = h.model.appliedState.file(for: 1)
        let scheduler = ManualScheduler()
        let keeper = DesktopKeeper(model: h.model, preferences: h.preferences, desktop: h.desktop, scheduler: scheduler)
        h.desktop.currentOverride[1] = URL(fileURLWithPath: "/other.png")
        h.desktop.delay = 1.2
        h.model.load(h.model.draft.reseeded(7))
        h.model.apply()
        #expect(h.model.isApplying)
        keeper.check(reason: "space")
        scheduler.fire()
        #expect(keeper.lastReport.contains("deferred"))
        await h.settle()
        h.desktop.delay = 0
        // The apply landing re-arms the keeper's check through
        // `observeChanges` (a `DispatchQueue.main.async` hop): wait for it,
        // then fire the re-armed debounce ourselves.
        await waitUntil { scheduler.pendingCount == 1 }
        scheduler.fire()
        let second = h.model.appliedState.file(for: 1)
        #expect(second != first)
        #expect(h.desktop.calls.filter { $0.url == first }.count == 1, "the old file was never put back")
        #expect(h.desktop.calls.last?.url == second && h.desktop.calls.last?.display == 1, "the new record was pinned")
    }

    // MARK: True black

    @Test("True black yields exact zeros from every composition and pair, on both sides")
    func trueBlackFromAnywhere() throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        let context = RenderContext(size: PixelSize(width: 64, height: 40), notch: NotchSpec(centerX: 32, width: 20, height: 8), menuBarStrip: 8)
        for composition in Composition.allCases {
            for pair in [PairMode.still, .lightDark, .timeOfDay(frames: 3)] {
                h.model.load(Wallpaper.starter)
                h.model.edit { $0.composition = composition; $0.pair = pair; $0.grain = 0.5; $0.finish.topShade = 0.4; $0.darkGenerator = .solid(SolidParameters(color: .white)) }
                h.model.useTrueBlack()
                let document = h.model.draft
                #expect(document.isTrueBlack, "\(composition) \(pair)")
                for side in [Side.light, .dark] {
                    let raster = WallpaperRenderer().render(document, side: side, context: context)
                    #expect(Self.rgbAllZero(raster), "\(composition) \(pair) \(side)")
                }
            }
        }
    }

    private static func rgbAllZero(_ raster: Raster) -> Bool {
        var i = 0
        while i + 2 < raster.pixels.count {
            if raster.pixels[i] != 0 || raster.pixels[i + 1] != 0 || raster.pixels[i + 2] != 0 { return false }
            i += 4
        }
        return true
    }

    // MARK: Clock

    @Test("The clock ticks only while a face is on screen")
    func clockTicksOnlyWhenShown() {
        let shown = ClockVisibility.shown(displays: [1, 2], isFullscreen: { $0 == 1 })
        #expect(shown == [2] && ClockVisibility.ticks(shown: shown))
        #expect(!ClockVisibility.ticks(shown: ClockVisibility.shown(displays: [1, 2], isFullscreen: { _ in true })))
        #expect(!ClockVisibility.ticks(shown: ClockVisibility.shown(displays: [], isFullscreen: { _ in false })))
    }

    // MARK: Shuffle

    @Test("Shuffle applies nothing when every choice is on the never-show list")
    func shuffleFailsClosed() async throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        h.preferences.favoritesOnly = false
        // Every seed the planner can draw is blocked: the draft's own seed
        // family, by blocking whatever the planner picks, six rounds deep.
        var generator = SeededGenerator(seed: 1)
        for _ in 0..<12 {
            let plan = ShufflePlanner.plan(displays: AppModelTests.Harness.displays, current: [:], favorites: [], favoritesOnly: false, sameOnAllDisplays: true, using: &generator)
            for document in plan.values { try h.model.blocklist.add(document) }
        }
        let before = h.desktop.calls.count
        let draft = h.model.draft
        h.model.shuffle(seed: 1)
        await h.settle()
        #expect(h.desktop.calls.count == before, "no apply")
        #expect(h.model.draft == draft, "the draft is untouched")
        #expect(h.model.status?.tone == .error && h.model.status?.text.contains("never-show") == true)
    }
}

/// The merged panel-polish and generator-depth branches, at the app level:
/// pins are the user's own setting, mirrored onto whatever document the
/// draft shows; a preset applies through the same readability lift every
/// other document goes through; the Generators list's family picker.
@MainActor
struct MergedPinsAndPaletteTests {
    @Test("A pin mirrors into the draft at once and survives loading another document")
    func pinMirrorsIntoDraft() {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.model.pin(.seed)
        h.model.pin(.palette)
        #expect(h.model.draft.pinned == h.model.pinnedKeys, "pinning mirrors into the draft at once")
        h.model.load(Wallpaper.starter.reseeded(9))
        #expect(h.model.draft.pinned == h.model.pinnedKeys, "load() mirrors the current pins onto whatever it shows")
        h.model.unpin(.seed)
        #expect(h.model.draft.pinned == [.palette], "unpinning mirrors too, without a fresh load")
    }

    @Test("applyPreset lifts the top shade only when the palette actually needs it; a preset that already reads is left alone")
    func applyPresetLiftsOnlyWhenNeeded() {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        var liftedSomewhere = false, leftAloneSomewhere = false
        for preset in Palettes.presets {
            // A busy mesh, seeded so its control points land the same way
            // every time: some preset/mesh pairs read as shipped, others
            // need the strip shaded — exactly what applyPreset is for.
            h.model.load(Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: [.black, .white], jitter: 0.9, softness: 0.3)), seed: 7))
            h.model.applyPreset(preset)
            if h.model.draft.finish.topShade > 0 { liftedSomewhere = true } else { leftAloneSomewhere = true }
            #expect(Side.allCases.allSatisfy { h.model.draft.menuBarReads(side: $0, context: h.model.readabilityContext) }, "\(preset.name): applyPreset must always leave a readable menu bar")
        }
        #expect(liftedSomewhere, "at least one preset needed the lift")
        #expect(leftAloneSomewhere, "at least one preset already read and was left alone")
    }

    @Test("generatorChoice = .family(.relief) switches to a field of that family")
    func generatorChoiceSwitchesFamily() {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.model.generatorChoice = .family(.relief)
        guard case .field(let p) = h.model.editedGenerator else { Issue.record("not a field"); return }
        #expect(p.family == .relief)
        #expect(h.model.generatorChoice == .family(.relief))
    }
}
