import Foundation
@testable import MacPaper
import MacPaperCore
import OpenAppsLicensing
import SwiftUI
import Testing

/// A wait a fake can park on until the test lets it go.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if isOpen {
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                }
            }
        }
    }

    var isWaiting: Bool { lock.withLock { !continuations.isEmpty } }

    func release() {
        let parked: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { continuations = [] }
            return continuations
        }
        for continuation in parked { continuation.resume() }
    }
}

/// The picker as an open panel: answers only once released.
final class GatedPicker: ImagePicker, @unchecked Sendable {
    let gate = Gate()
    var url: URL?
    func pickImage() async -> URL? {
        await gate.wait()
        return url
    }
}

/// The exporter as a save panel left open: waits, then asks `mayWrite`
/// exactly as the app's does after `runModal`, and keeps what it wrote.
final class GatedExporter: FileExporter, @unchecked Sendable {
    let gate = Gate()
    private(set) var exported: [String] = []
    /// Runs after each file is written (the user taking a while between two
    /// save panels).
    var afterWrite: @Sendable () -> Void = {}
    func export(_ data: Data, named name: String, to folder: URL, mayWrite: @escaping @MainActor () -> Bool) async throws -> URL {
        await gate.wait()
        guard mayWrite() else { throw AppModel.Refused() }
        exported.append(name)
        afterWrite()
        return folder.appendingPathComponent(name)
    }
}

/// A desktop whose first apply takes long enough for a deadline to pass:
/// `onApply` runs inside the call, before it returns. It can refuse HEIC
/// files (a display that only takes stills), running `onRefuse` then.
final class SlowDesktop: DesktopApplier, @unchecked Sendable {
    struct RefusedHEIC: Error {}
    private let lock = NSLock()
    private var recorded: [(DisplayID, URL)] = []
    var onApply: @Sendable () -> Void = {}
    var onRefuse: @Sendable () -> Void = {}
    var refusesHEIC = false
    var calls: [DisplayID] { lock.withLock { recorded.map(\.0) } }
    var urls: [URL] { lock.withLock { recorded.map(\.1) } }
    func apply(imageAt url: URL, to display: DisplayID) throws {
        if refusesHEIC, url.pathExtension == "heic" {
            onRefuse()
            throw RefusedHEIC()
        }
        lock.withLock { recorded.append((display, url)) }
        onApply()
    }
    func currentImageURL(for display: DisplayID) -> URL? { lock.withLock { recorded.last { $0.0 == display }?.1 } }
}

/// Work started while allowed and finished after the trial ended, with no
/// tick, no timer and no re-render in between: a control's binding held by
/// a view, an open image picker, a render or a save panel in flight, one
/// display applied and the next still to go. The real manager's projection
/// decides at every resumption; nothing started under the grant commits
/// after it lapsed.
@Suite("Continuations across a deadline")
@MainActor
struct ContinuationTests {
    let clock = FakeClock()
    let trialStore = MemoryTrialStore()
    let feed = SnapshotBox()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-continuations-\(UUID().uuidString)", isDirectory: true)
    let desktop = SlowDesktop()
    let exporter = GatedExporter()
    let picker = GatedPicker()
    let license = LicenseStatus()
    /// Removed with the directory; a suite lives under the temporary
    /// directory, never in ~/Library/Preferences.
    let temporaryDefaults = Suites()

    final class Suites: @unchecked Sendable {
        private(set) var all: [TemporaryDefaults] = []
        func append(_ suite: TemporaryDefaults) { all.append(suite) }
    }

    /// The model over the fakes, its status bound to the manager's
    /// projection, one minute of trial left.
    func attach(secondsLeft: TimeInterval = 60) async -> AppModel {
        trialStore.record = TrialRecord(startedAt: clock.now.addingTimeInterval(-(3 * FakeClock.day - secondsLeft)), lastSeenAt: clock.now, registered: true)
        let clock = self.clock
        let feed = self.feed
        let manager = LicenseManager(
            appID: Licensing.appID, products: LicenseProducts(paid: [EnforcementTests.paid]), client: FakeClient(), store: MemoryStore(),
            journal: MemoryJournal(), trialStore: trialStore, registry: FakeRegistry(), device: FakeDevice(),
            trialTiming: Licensing.trialTiming, now: { clock.now }, uptime: { clock.uptime }
        )
        await manager.setOnChange { feed.snapshot = $0 }
        await manager.load()
        await manager.checkOnLaunch()
        let project: () -> LicenseState = { feed.snapshot.state(now: clock.now, uptime: clock.uptime) }
        license.bind(
            access: { project().isFeatureEnabled }, state: { project() },
            restriction: { LicenseRestriction.card(for: project()) },
            badge: { LicenseBadge.label(for: project(), appName: Licensing.appName) }, canBuy: true
        )
        let temporary = try! TemporaryDefaults()
        temporaryDefaults.append(temporary)
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.sameOnAllDisplays = true
        let model = AppModel(
            preferences: preferences, license: license, paths: AppPaths(root: directory), desktop: desktop,
            exporter: exporter, imagePicker: picker, displays: { AppModelTests.Harness.displays }
        )
        model.setExportReveal { _ in }
        model.appliesLive = false
        #expect(license.hasAccess())
        return model
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        for suite in temporaryDefaults.all { suite.remove() }
    }

    func settle(_ model: AppModel) async {
        for _ in 0..<500 where model.isApplying || model.isExporting {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForGate(_ gate: Gate) async {
        for _ in 0..<500 where !gate.isWaiting {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.isWaiting)
    }

    /// PNG files the applier wrote and kept.
    func appliedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: directory).appliedImages.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    }

    @Test("A binding held by a rendered control: set after the deadline, it changes, renders and saves nothing")
    func retainedBindingAfterExpiry() async {
        let model = await attach()
        defer { tearDown() }
        // The bindings as the editors build them, captured while allowed.
        let grain = model.binding(\.grain)
        let generator = Binding<Generator>(get: { model.editedGenerator }, set: { model.editedGenerator = $0 })
        let kind = Binding<GeneratorKind>(get: { model.generatorKind }, set: { model.generatorKind = $0 })
        let topShade = model.binding(\.finish.topShade)
        grain.wrappedValue = 0.25
        #expect(model.draft.grain == 0.25, "allowed: the edit lands")
        for _ in 0..<200 where model.previewWallpaper != model.draft { try? await Task.sleep(for: .milliseconds(10)) }
        let before = model.draft
        let previewBefore = model.previewWallpaper

        clock.advance(120) // the trial ended; no tick, no timer, no body re-evaluated
        grain.wrappedValue = 0.9
        generator.wrappedValue = Generator.solid(SolidParameters(color: RGBAColor(hex: 0x123456)))
        kind.wrappedValue = .pattern
        topShade.wrappedValue = 0.6
        model.setPair(.lightDark)
        model.useTrueBlack()
        #expect(model.draft == before, "no edit lands")
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        try? await Task.sleep(for: .milliseconds(500)) // past the draft save's debounce
        #expect(model.previewWallpaper == previewBefore, "no render")
        #expect(AppliedStore(fileURL: AppPaths(root: directory).applied).current.draft == nil || AppliedStore(fileURL: AppPaths(root: directory).applied).current.draft == before, "no save of a refused edit")
    }

    @Test("Import Image left open across the deadline: choosing a file then imports nothing")
    func importPickerAcrossExpiry() async throws {
        let model = await attach()
        defer { tearDown() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("source.png")
        try WallpaperRenderer().render(.starter, size: PixelSize(width: 8, height: 8)).pngData()!.write(to: image)
        picker.url = image
        let before = model.draft
        let importing = Task { await model.importImage() }
        await waitForGate(picker.gate)
        clock.advance(120)
        picker.gate.release()
        await importing.value
        #expect(model.draft == before)
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        let imports = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: directory).imports.path)) ?? []
        #expect(imports.isEmpty, "nothing decoded or copied")
    }

    @Test("Apply whose render crosses the deadline: nothing reaches the desktop, the file is discarded")
    func applyRenderAcrossExpiry() async {
        let model = await attach()
        defer { tearDown() }
        model.apply()
        #expect(model.isApplying)
        clock.advance(120) // before the detached render can hand back
        await settle(model)
        #expect(desktop.calls.isEmpty)
        #expect(model.appliedState.byDisplay.isEmpty)
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        #expect(appliedFiles().isEmpty, "the prepared files are discarded")
    }

    @Test("The deadline passes between two displays: the first stays applied, the second is never touched")
    func applyBetweenDisplays() async {
        let model = await attach()
        defer { tearDown() }
        let clock = self.clock
        desktop.onApply = { clock.advance(120) }
        model.apply()
        await settle(model)
        #expect(desktop.calls == [1])
        #expect(model.appliedState.wallpaper(for: 1) == model.draft)
        #expect(model.appliedState.wallpaper(for: 2) == nil)
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        #expect(appliedFiles() == ["1-1.png"], "the second display's file is discarded, the first kept")
        // Nothing more happens on a later click either.
        model.apply()
        await settle(model)
        #expect(desktop.calls == [1])
    }

    @Test("A display refuses the HEIC and the deadline passes before the fallback: no still reaches it, both files discarded")
    func heicFallbackAcrossExpiry() async {
        let model = await attach()
        defer { tearDown() }
        let clock = self.clock
        desktop.refusesHEIC = true
        desktop.onRefuse = { clock.advance(120) }
        model.setPair(.lightDark)
        model.apply()
        await settle(model)
        #expect(desktop.calls.isEmpty, "the fallback still was never handed over")
        #expect(model.appliedState.byDisplay.isEmpty)
        #expect(appliedFiles().isEmpty, "the refused HEIC and the still are both discarded")
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
    }

    @Test("With time to spare the refused HEIC falls back to a still, marked so the theme swap follows")
    func heicFallbackWithinTheTrial() async {
        let model = await attach(secondsLeft: FakeClock.day)
        defer { tearDown() }
        desktop.refusesHEIC = true
        model.setPair(.lightDark)
        model.apply()
        await settle(model)
        #expect(desktop.calls == [1, 2])
        #expect(desktop.urls.allSatisfy { $0.pathExtension == "png" })
        #expect(model.appliedState.fallbackDisplayIDs == [1, 2])
        #expect(appliedFiles() == ["1-2.png", "2-2.png"], "the refused HEICs are gone, the stills kept")
    }

    @Test("The theme swap after the deadline touches no display; the sides applied stay")
    func themeSwapAcrossExpiry() async {
        let model = await attach()
        defer { tearDown() }
        desktop.refusesHEIC = true
        model.systemAppearance = { .light }
        model.setPair(.lightDark)
        model.apply()
        await settle(model)
        #expect(model.appliedState.fallbackDisplayIDs == [1, 2])
        let before = desktop.urls
        clock.advance(120)
        model.systemAppearance = { .dark }
        model.themeChanged()
        await settle(model)
        #expect(desktop.urls == before, "nothing swapped")
        #expect(appliedFiles() == ["1-2.png", "2-2.png"], "the prepared dark stills are discarded")
        #expect(model.appliedState.file(for: 1) == before[0] && model.appliedState.file(for: 2) == before[1])
    }

    @Test("Export whose render crosses the deadline writes nothing")
    func exportRenderAcrossExpiry() async {
        let model = await attach()
        defer { tearDown() }
        exporter.gate.release()
        model.export(.png)
        #expect(model.isExporting)
        clock.advance(120)
        await settle(model)
        #expect(exporter.exported.isEmpty)
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
    }

    @Test("A save panel left open across the deadline: Save writes nothing")
    func exportPanelAcrossExpiry() async {
        let model = await attach()
        defer { tearDown() }
        model.export(.svg)
        await waitForGate(exporter.gate)
        clock.advance(120)
        exporter.gate.release()
        await settle(model)
        #expect(exporter.exported.isEmpty)
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        #expect(!model.isExporting, "the busy flag is reset")
    }

    @Test("A multi-file export: the deadline between two files stops the second")
    func multiFileExportAcrossExpiry() async {
        let model = await attach()
        defer { tearDown() }
        exporter.gate.release()
        let clock = self.clock
        exporter.afterWrite = { clock.advance(120) }
        model.export(.phonePair)
        await settle(model)
        #expect(exporter.exported.count == 1, "the desktop PNG was written before the deadline, the phone PNG refused after it")
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error))
        #expect(!model.isExporting)
    }

    @Test("The same work, with time to spare, completes")
    func withinTheTrialEverythingCompletes() async {
        let model = await attach(secondsLeft: FakeClock.day)
        defer { tearDown() }
        exporter.gate.release()
        model.apply()
        await settle(model)
        #expect(desktop.calls == [1, 2])
        #expect(appliedFiles() == ["1-1.png", "2-1.png"])
        model.export(.png)
        await settle(model)
        #expect(exporter.exported == [WallpaperExport.fileName(for: .starter, format: .png)])
        #expect(model.status?.tone == .info)
    }
}
