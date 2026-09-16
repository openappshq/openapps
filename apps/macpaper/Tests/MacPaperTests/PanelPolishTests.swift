import AppKit
import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// Live apply over the recording applier: every change lands on the
/// desktop on its own, debounced; the last state wins; a change during a
/// render leaves that render's files discarded; restricted, nothing lands.
@MainActor
struct LiveApplyTests {
    /// A harness with live apply on and a short debounce.
    func harness(delay: Duration = .milliseconds(60)) -> AppModelTests.Harness {
        let h = AppModelTests.Harness()
        h.model.appliesLive = true
        h.model.liveApplyDelay = delay
        h.preferences.sameOnAllDisplays = true
        return h
    }

    /// Waits past the debounce and for the chain to drain.
    func settle(_ h: AppModelTests.Harness, past delay: Duration = .milliseconds(60)) async {
        try? await Task.sleep(for: delay + .milliseconds(80))
        await h.settle()
    }

    @Test("An edit reaches the desktop after the debounce, without a status line")
    func editApplies() async {
        let h = harness()
        defer { h.tearDown() }
        h.model.edit { $0.grain = 0.4 }
        #expect(h.desktop.calls.isEmpty, "nothing before the debounce")
        await settle(h)
        #expect(Set(h.desktop.calls.map(\.display)) == [1, 2])
        #expect(h.model.appliedState.wallpaper(for: 1) == h.model.draft)
        #expect(h.model.currentApplied == h.model.draft)
        #expect(h.model.status == nil, "a live apply says nothing on success")
        #expect(h.model.liveApplyCount == 1)
        #expect(h.model.historyList.first?.wallpaper == h.model.draft, "the look is in the history")
    }

    @Test("Changes inside the debounce coalesce into one apply of the last state")
    func debounce() async {
        let h = harness()
        defer { h.tearDown() }
        for grain in [0.1, 0.2, 0.3, 0.4, 0.5] {
            h.model.edit { $0.grain = grain }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await settle(h)
        #expect(h.model.liveApplyCount == 1)
        #expect(h.desktop.calls.count == 2)
        #expect(h.model.appliedState.wallpaper(for: 1)?.grain == 0.5)
    }

    @Test("A change during a render supersedes it: its files are discarded before any desktop call, and the last state lands once")
    func lastWins() async {
        let h = harness(delay: .milliseconds(20))
        defer { h.tearDown() }
        h.desktop.delay = 0.3
        h.model.edit { $0.grain = 0.2 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(h.model.isApplying, "the first live apply is rendering or committing")
        // A second change while the first is in flight: it queues behind it.
        h.model.edit { $0.grain = 0.9 }
        try? await Task.sleep(for: .milliseconds(30))
        // A third change before the second starts: the second is superseded while it waits.
        h.model.edit { $0.grain = 0.7 }
        await settle(h, past: .milliseconds(1200))
        #expect(h.model.appliedState.wallpaper(for: 1)?.grain == 0.7, "the last state is on the desktop")
        // Only committed files remain in the applied folder: the superseded render was discarded.
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: h.directory).appliedImages.path)) ?? []).filter { $0.hasSuffix(".png") }
        let committed = Set(h.desktop.calls.map(\.url.lastPathComponent))
        #expect(Set(files).isSubset(of: committed), "nothing prepared but never committed is left: \(files) vs \(committed)")
        #expect(h.model.liveApplyCount >= 2 && h.desktop.calls.count <= 6)
        #expect(!h.model.isApplying)
    }

    @Test("A change that supersedes a render in progress discards that render's files")
    func cancelledRender() async {
        let h = harness(delay: .milliseconds(20))
        defer { h.tearDown() }
        // A big enough display that the render takes a while.
        h.model.edit { $0.grain = 0.2 }
        try? await Task.sleep(for: .milliseconds(25))
        // Right as the first apply starts rendering, another change bumps the generation.
        h.model.edit { $0.grain = 0.8 }
        await settle(h, past: .milliseconds(400))
        #expect(h.model.appliedState.wallpaper(for: 1)?.grain == 0.8)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: h.directory).appliedImages.path)) ?? []).filter { $0.hasSuffix(".png") }
        let committed = Set(h.desktop.calls.map(\.url.lastPathComponent))
        #expect(Set(files).isSubset(of: committed))
    }

    @Test("A loaded favorite, a shuffle and a preset land too; an explicit apply drops the pending live one")
    func loadsAndShuffles() async {
        let h = harness()
        defer { h.tearDown() }
        h.model.load(Wallpaper.starter.reseeded(11))
        await settle(h)
        #expect(h.model.appliedState.wallpaper(for: 1)?.seed == 11)
        let before = h.desktop.calls.count
        h.model.applyPreset(PresetPalettes.named("Sea")!)
        await settle(h)
        #expect(h.desktop.calls.count == before + 2)
        #expect(PresetPalettes.matching(h.model.appliedState.wallpaper(for: 1)!.generator.colors)?.name == "Sea")
        let beforeShuffle = h.desktop.calls.count
        h.model.shuffle(seed: 5)
        await settle(h)
        #expect(h.desktop.calls.count == beforeShuffle + 2, "the shuffle applies once; no live apply follows it")
        #expect(h.model.appliedState.wallpaper(for: 1) == h.model.draft)
        let beforeApply = h.desktop.calls.count
        h.model.edit { $0.grain = 0.33 }
        h.model.apply()
        await settle(h)
        #expect(h.desktop.calls.count == beforeApply + 2, "the explicit apply lands the draft; the pending live one is dropped")
    }

    @Test("Restricted, nothing reaches the desktop: an edit is refused and a loaded favorite stays a preview")
    func refused() async {
        let h = harness()
        defer { h.tearDown() }
        h.license.bind(access: { false }, restriction: { .trialEndedSample }, canBuy: true)
        h.model.edit { $0.grain = 0.4 }
        #expect(h.model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        h.model.clearStatus()
        h.model.load(Wallpaper.starter.reseeded(3))
        await settle(h)
        #expect(h.desktop.calls.isEmpty)
        #expect(h.model.appliedState.byDisplay.isEmpty)
        #expect(h.model.status == nil, "browsing while restricted is quiet; the card says why")
        #expect(h.model.liveApplyCount == 0)
        // Allowed again: the next change lands.
        h.license.bind(access: { true }, restriction: { nil }, canBuy: false)
        h.model.edit { $0.grain = 0.5 }
        await settle(h)
        #expect(h.desktop.calls.count == 2)
    }

    @Test("The reach control: this display, every display, this Space only")
    func reach() async {
        let h = harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = false
        #expect(ApplyReach.available(sameOnAllDisplays: false, displayCount: 2) == [.thisDisplay, .everyDisplay, .thisSpace])
        #expect(ApplyReach.available(sameOnAllDisplays: true, displayCount: 2) == [.everyDisplay, .thisSpace])
        #expect(ApplyReach.available(sameOnAllDisplays: false, displayCount: 1) == [.everyDisplay, .thisSpace])
        h.model.reach = .thisDisplay
        h.model.targetDisplay = 2
        h.model.edit { $0.grain = 0.2 }
        await settle(h)
        #expect(h.desktop.calls.map(\.display) == [2])
        h.model.reach = .thisSpace
        h.model.edit { $0.grain = 0.3 }
        await settle(h)
        #expect(h.desktop.calls.map(\.display) == [2, 2] && h.model.appliedState.perSpaceDisplayIDs == [2])
        h.model.reach = .everyDisplay
        h.model.edit { $0.grain = 0.4 }
        await settle(h)
        #expect(Set(h.desktop.calls.suffix(2).map(\.display)) == [1, 2] && h.model.appliedState.perSpaceDisplayIDs.isEmpty)
    }

    @Test("Pins are kept through Shuffle and persist in the preferences")
    func pins() async {
        let h = harness()
        defer { h.tearDown() }
        h.model.load(Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: PresetPalettes.named("Sea")!.colors, jitter: 0.77, softness: 0.5)), seed: 4))
        h.model.togglePin(.palette)
        h.model.togglePin(.meshJitter)
        #expect(h.model.isPinned(.palette) && h.model.pins.pins == [.palette, .meshJitter])
        h.model.shuffle(seed: 8)
        await settle(h)
        guard case .mesh(let p) = h.model.draft.generator else { Issue.record("the generator changed"); return }
        #expect(p.jitter == 0.77 && p.colors == PresetPalettes.named("Sea")!.colors)
        #expect(h.model.draft.seed != 4)
        #expect(Preferences(defaults: h.defaults).pins == h.model.pins, "persisted")
        h.model.togglePin(.palette)
        #expect(!h.model.isPinned(.palette))
    }

    @Test("Save names a recipe; the Library's field starts with the derived title")
    func library() async {
        let h = harness()
        defer { h.tearDown() }
        h.model.load(StarterRecipes.all[0].wallpaper)
        #expect(h.model.recipeTitle == "Tangerine · Mesh")
        h.model.saveRecipe(named: "  ")
        #expect(h.model.favoriteList[0].title == "Tangerine · Mesh")
        h.model.saveRecipe(named: "Desk")
        #expect(h.model.favoriteList.count == 1 && h.model.favoriteList[0].title == "Desk" && h.model.recipeTitle == "Desk")
        h.model.neverShow(h.model.favoriteList[0])
        #expect(h.model.favoriteList.isEmpty && h.model.blockedCount == 1)
        #expect(h.model.draft == StarterRecipes.all[0].wallpaper, "the draft is left alone")
    }
}

/// The column's controls, measured in the real fonts.
@MainActor
struct PanelWidthTests {
    init() {
        AppResources.registerFonts()
    }

    @Test("Every segmented control fits the compact column on one line, and the width setting grows only when it must")
    func segmentsFit() {
        let pane = PanelLayout.paneWidth(columnWidth: PanelMetrics.width(for: .compact))
        for labels in [Composition.allCases.map(\.title), GradientKind.allCases.map(\.title), PatternKind.allCases.map(\.title), ImageFit.allCases.map(\.title), PairChoice.allCases.map(\.title), BaseLayer.allCases.map(\.title)] {
            let width = LabelMeasure.segmentedWidth(labels)
            #expect(width <= pane, "\(labels) needs \(width) in a pane of \(pane)")
            // Every segment is at least as wide as its widest label plus the padding.
            let widest = LabelMeasure.segmentWidths(labels).max()!
            #expect(width >= CGFloat(labels.count) * (widest + 2 * PanelLayout.segmentPadding))
        }
        let widest = PanelMetrics.controlWidths.max()!
        for setting in PanelWidth.allCases {
            let width = PanelMetrics.width(for: setting)
            #expect(width >= setting.points)
            #expect(PanelLayout.paneWidth(columnWidth: width) >= widest, "the widest control fits the \(setting.rawValue) column")
            #expect(width == max(setting.points, ceil(widest + PanelLayout.railWidth + 2 * PanelLayout.paneInset)))
        }
        #expect(PanelMetrics.width(for: .regular) == PanelWidth.regular.points, "the regular column needs no growth")
    }

    @Test("Labels measure as drawn: wider text, wider segment")
    func measure() {
        let font = Brand.bodyFont(SegmentMetrics.fontSize, weight: 600)
        #expect(LabelMeasure.width(of: "Painted pill", font: font) > LabelMeasure.width(of: "None", font: font))
        #expect(LabelMeasure.width(of: "", font: font) == 0)
        #expect(font.familyName == "Instrument Sans", "the brand font is registered")
    }
}
