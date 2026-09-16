import AppKit
import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// The debounce as the tests drive it: nothing fires until `fire()`.
final class ManualScheduler: DelayScheduler {
    private final class Token: ScheduledToken {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private var pending: [(Token, @MainActor () -> Void)] = []
    private(set) var scheduled = 0

    var pendingCount: Int { pending.filter { !$0.0.cancelled }.count }

    func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) -> any ScheduledToken {
        let token = Token()
        pending.append((token, fire))
        scheduled += 1
        return token
    }

    /// Fires every pending, uncancelled delay, in order.
    @MainActor func fire() {
        let items = pending
        pending = []
        for (token, fire) in items where !token.cancelled { fire() }
    }
}

/// A desktop whose applies block until released: an apply is held in
/// flight for exactly as long as a test wants.
final class GatedApplier: DesktopApplier, @unchecked Sendable {
    private let lock = NSLock()
    struct Call { let url: URL; let display: DisplayID }
    private var recorded: [Call] = []
    private let gate = DispatchSemaphore(value: 0)
    private var open = false
    private(set) var waiting = false

    var calls: [Call] { lock.withLock { recorded } }
    /// An apply is held at the gate.
    var isWaiting: Bool { lock.withLock { waiting } }

    func apply(imageAt url: URL, to display: DisplayID) throws {
        let mustWait = lock.withLock { () -> Bool in
            if !open { waiting = true }
            return !open
        }
        if mustWait { gate.wait() }
        lock.withLock { recorded.append(Call(url: url, display: display)) }
    }

    func currentImageURL(for display: DisplayID) -> URL? {
        lock.withLock { recorded.last { $0.display == display }?.url }
    }

    /// Lets the held apply through, and every one after it.
    func release() {
        lock.withLock { open = true }
        gate.signal()
    }
}

/// Live apply over a manual debounce and the recording applier: every
/// change lands on the desktop on its own; the last state wins; a change
/// during a render leaves that render's files discarded; restricted,
/// nothing lands. No wall-clock waits: the scheduler fires on demand, the
/// only waiting is for the apply chain to drain.
@MainActor
struct LiveApplyTests {
    /// A harness with live apply on and the manual debounce.
    func harness() -> (AppModelTests.Harness, ManualScheduler) {
        let h = AppModelTests.Harness()
        let scheduler = ManualScheduler()
        h.model.appliesLive = true
        h.model.liveScheduler = scheduler
        h.preferences.sameOnAllDisplays = true
        return (h, scheduler)
    }

    /// Fires the debounce and waits for the chain to drain.
    func land(_ h: AppModelTests.Harness, _ scheduler: ManualScheduler) async {
        scheduler.fire()
        await h.settle()
    }

    func appliedFiles(_ h: AppModelTests.Harness) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: h.directory).appliedImages.path)) ?? []).filter { $0.hasSuffix(".png") })
    }

    @Test("An edit reaches the desktop after the debounce, without a status line")
    func editApplies() async {
        let (h, scheduler) = harness()
        defer { h.tearDown() }
        h.model.edit { $0.grain = 0.4 }
        #expect(h.desktop.calls.isEmpty && scheduler.pendingCount == 1, "armed, nothing before the debounce")
        await land(h, scheduler)
        #expect(Set(h.desktop.calls.map(\.display)) == [1, 2])
        #expect(h.model.appliedState.wallpaper(for: 1) == h.model.draft)
        #expect(h.model.currentApplied == h.model.draft)
        #expect(h.model.status == nil, "a live apply says nothing on success")
        #expect(h.model.liveApplyCount == 1)
        #expect(h.model.historyList.first?.wallpaper == h.model.draft, "the look is in the history")
    }

    @Test("Changes inside the debounce coalesce into one apply of the last state")
    func debounce() async {
        let (h, scheduler) = harness()
        defer { h.tearDown() }
        for grain in [0.1, 0.2, 0.3, 0.4, 0.5] { h.model.edit { $0.grain = grain } }
        #expect(scheduler.scheduled == 5 && scheduler.pendingCount == 1, "each change re-arms; only the last is live")
        await land(h, scheduler)
        #expect(h.model.liveApplyCount == 1)
        #expect(h.desktop.calls.count == 2)
        #expect(h.model.appliedState.wallpaper(for: 1)?.grain == 0.5)
    }

    @Test("A change while an apply is committing queues behind it; a further change supersedes the queued one: the last state lands once")
    func lastWins() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        let scheduler = ManualScheduler()
        let gated = GatedApplier()
        let model = AppModel(
            preferences: h.preferences, license: h.license, paths: AppPaths(root: h.directory), desktop: gated,
            exporter: h.exporter, imagePicker: h.picker, displays: { AppModelTests.Harness.displays }
        )
        model.systemAppearance = { .light }
        model.liveScheduler = scheduler
        h.preferences.sameOnAllDisplays = true
        model.edit { $0.grain = 0.2 }
        scheduler.fire()
        #expect(model.isApplying)
        // The first apply renders and is then held at its first desktop call.
        for _ in 0..<2000 where !gated.isWaiting { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(gated.isWaiting)
        // A second change queues behind it; a third supersedes the second while it waits.
        model.edit { $0.grain = 0.9 }
        scheduler.fire()
        model.edit { $0.grain = 0.7 }
        scheduler.fire()
        #expect(model.liveApplyCount == 3)
        gated.release()
        for _ in 0..<1000 where model.isApplying { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isApplying)
        #expect(model.appliedState.wallpaper(for: 1)?.grain == 0.7, "the last state is on the desktop")
        #expect(gated.calls.count == 4, "the first apply and the last, two displays each; the superseded one never rendered")
        #expect(!gated.calls.isEmpty)
        let committed = Set(gated.calls.map(\.url.lastPathComponent))
        let files = Set(((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: h.directory).appliedImages.path)) ?? []).filter { $0.hasSuffix(".png") })
        #expect(files.isSubset(of: committed), "nothing prepared but never committed is left: \(files) vs \(committed)")
    }

    @Test("A change during a render supersedes it: the render's files are discarded before any desktop call")
    func cancelledRender() async {
        let (h, scheduler) = harness()
        defer { h.tearDown() }
        h.model.edit { $0.grain = 0.2 }
        // Right after the render, before the desktop is touched, the draft changes again.
        h.model.afterPrepare = { [model = h.model] in
            model.afterPrepare = {}
            model.edit { $0.grain = 0.8 }
        }
        await land(h, scheduler)
        #expect(h.desktop.calls.isEmpty, "the superseded render reached no desktop")
        #expect(h.model.appliedState.byDisplay.isEmpty)
        #expect(appliedFiles(h).isEmpty, "its files are discarded")
        #expect(scheduler.pendingCount == 1, "the change that superseded it is armed")
        await land(h, scheduler)
        #expect(h.model.appliedState.wallpaper(for: 1)?.grain == 0.8)
        #expect(h.desktop.calls.count == 2)
        #expect(appliedFiles(h) == Set(h.desktop.calls.map(\.url.lastPathComponent)))
    }

    @Test("A loaded favorite, a shuffle and a preset land too; an explicit apply drops the pending live one")
    func loadsAndShuffles() async {
        let (h, scheduler) = harness()
        defer { h.tearDown() }
        h.model.load(Wallpaper.starter.reseeded(11))
        await land(h, scheduler)
        #expect(h.model.appliedState.wallpaper(for: 1)?.seed == 11)
        let before = h.desktop.calls.count
        h.model.applyPreset(PresetPalettes.named("Sea")!)
        await land(h, scheduler)
        #expect(h.desktop.calls.count == before + 2)
        #expect(PresetPalettes.matching(h.model.appliedState.wallpaper(for: 1)!.generator.colors)?.name == "Sea")
        #expect(Side.allCases.allSatisfy { h.model.draft.menuBarReads(side: $0, context: h.model.readabilityContext) }, "a preset lands with a readable menu bar")
        let beforeShuffle = h.desktop.calls.count
        h.model.shuffle(seed: 5)
        #expect(scheduler.pendingCount == 0, "the shuffle applies itself; no live apply is armed")
        await h.settle()
        #expect(h.desktop.calls.count == beforeShuffle + 2)
        #expect(h.model.appliedState.wallpaper(for: 1) == h.model.draft)
        let beforeApply = h.desktop.calls.count
        h.model.edit { $0.grain = 0.33 }
        #expect(scheduler.pendingCount == 1)
        h.model.apply()
        #expect(scheduler.pendingCount == 0, "the explicit apply drops the pending live one")
        await h.settle()
        #expect(h.desktop.calls.count == beforeApply + 2)
    }

    @Test("Restricted, nothing reaches the desktop: an edit is refused and a loaded favorite stays a preview")
    func refused() async {
        let (h, scheduler) = harness()
        defer { h.tearDown() }
        h.license.bind(access: { false }, restriction: { .trialEndedSample }, canBuy: true)
        h.model.edit { $0.grain = 0.4 }
        #expect(h.model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        h.model.clearStatus()
        h.model.load(Wallpaper.starter.reseeded(3))
        await land(h, scheduler)
        #expect(h.desktop.calls.isEmpty)
        #expect(h.model.appliedState.byDisplay.isEmpty)
        #expect(h.model.status == nil, "browsing while restricted is quiet; the card says why")
        #expect(h.model.liveApplyCount == 0)
        // Allowed again: the next change lands.
        h.license.bind(access: { true }, restriction: { nil }, canBuy: false)
        h.model.edit { $0.grain = 0.5 }
        await land(h, scheduler)
        #expect(h.desktop.calls.count == 2)
    }

    @Test("The reach control: this display, every display, this Space only")
    func reach() async {
        let (h, scheduler) = harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = false
        #expect(ApplyReach.available(sameOnAllDisplays: false, displayCount: 2) == [.thisDisplay, .everyDisplay, .thisSpace])
        #expect(ApplyReach.available(sameOnAllDisplays: true, displayCount: 2) == [.everyDisplay, .thisSpace])
        #expect(ApplyReach.available(sameOnAllDisplays: false, displayCount: 1) == [.everyDisplay, .thisSpace])
        h.model.reach = .thisDisplay
        h.model.targetDisplay = 2
        h.model.edit { $0.grain = 0.2 }
        await land(h, scheduler)
        #expect(h.desktop.calls.map(\.display) == [2])
        h.model.reach = .thisSpace
        h.model.edit { $0.grain = 0.3 }
        await land(h, scheduler)
        #expect(h.desktop.calls.map(\.display) == [2, 2] && h.model.appliedState.perSpaceDisplayIDs == [2])
        h.model.reach = .everyDisplay
        h.model.edit { $0.grain = 0.4 }
        await land(h, scheduler)
        #expect(Set(h.desktop.calls.suffix(2).map(\.display)) == [1, 2] && h.model.appliedState.perSpaceDisplayIDs.isEmpty)
    }

    @Test("Pins are kept through Shuffle, on both sides, and persist in the preferences")
    func pins() async {
        let (h, _) = harness()
        defer { h.tearDown() }
        h.model.load(Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: PresetPalettes.named("Sea")!.colors, jitter: 0.77, softness: 0.5)), seed: 4))
        h.model.togglePin(.palette)
        h.model.togglePin(.meshJitter)
        #expect(h.model.isPinned(.palette) && h.model.pins.pins == [.palette, .meshJitter])
        h.model.shuffle(seed: 8)
        await h.settle()
        guard case .mesh(let p) = h.model.draft.generator else { Issue.record("the generator changed"); return }
        #expect(p.jitter == 0.77 && p.colors == PresetPalettes.named("Sea")!.colors)
        #expect(h.model.draft.seed != 4)
        #expect(Preferences(defaults: h.defaults).pins == h.model.pins, "persisted")
        // Editing the dark side: its pinned jitter survives as the dark side's.
        h.model.editingSide = .dark
        h.model.materializeDarkSide()
        h.model.editedGenerator = .mesh(MeshParameters(columns: 2, rows: 2, colors: [.black, .white], jitter: 0.11, softness: 0.5))
        h.model.shuffle(seed: 9)
        await h.settle()
        if case .mesh(let light) = h.model.draft.generator, case .mesh(let dark)? = h.model.draft.darkGenerator {
            #expect(light.jitter == 0.77 && dark.jitter == 0.11)
        } else {
            Issue.record("sides missing")
        }
        h.model.togglePin(.palette)
        #expect(!h.model.isPinned(.palette))
    }

    @Test("Save names a recipe; the Library's field starts with the derived title")
    func library() async {
        let (h, _) = harness()
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

    @Test("Preview renders coalesce: one in flight, one pending, the last state shown")
    func previewCoalesces() async {
        let (h, _) = harness()
        defer { h.tearDown() }
        for _ in 0..<200 where h.model.previewWallpaper != h.model.draft { try? await Task.sleep(for: .milliseconds(10)) }
        for step in 1...19 { h.model.edit { $0.grain = Double(step) / 20 } }
        for _ in 0..<500 where h.model.previewWallpaper != h.model.draft { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(h.model.previewWallpaper == h.model.draft)
        #expect(h.model.previewWallpaper?.grain == 0.95)
        #expect(h.model.previewCache.count <= 3, "at most the first render, one that was in flight and the last: \(h.model.previewCache.count)")
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
        // The time-of-day frame stepper sits under the pair segments, on its own line; it fits on any width too.
        let stepper = LabelMeasure.width(of: "16 frames", font: NSFont(name: "IBMPlexMono-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) + 2 * 26 + 2 * Brand.Space.s4
        #expect(stepper <= pane)
    }

    @Test("Labels measure as drawn: wider text, wider segment")
    func measure() {
        let font = Brand.bodyFont(SegmentMetrics.fontSize, weight: 600)
        #expect(LabelMeasure.width(of: "Painted pill", font: font) > LabelMeasure.width(of: "None", font: font))
        #expect(LabelMeasure.width(of: "", font: font) == 0)
        #expect(font.familyName == "Instrument Sans", "the brand font is registered")
    }
}
