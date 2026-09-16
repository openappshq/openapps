import Foundation
@testable import Hertz
import HertzCore
import OpenAppsLicensing
import Testing

/// The metrics model's gate on its own: collection, the held sample and the
/// exported report all follow `access()` as asked at that moment, with the
/// inert readers standing in for the collectors.
@Suite("Metrics model gate")
@MainActor
struct MetricsModelGateTests {
    let readers = CountingReaders()
    let access = StateBox(.trialUnavailable)

    func makeModel() -> MetricsModel {
        let model = MetricsModel(readers: { readers.readers })
        model.access = { access.state.isFeatureEnabled }
        return model
    }

    @Test("Nothing is read at creation, on start or on a tick while access is denied")
    func restrictedStartCollectsNothing() {
        let model = makeModel()
        #expect(readers.reads == 0 && readers.hardwareReads == 0)
        model.start()
        model.tick()
        model.tick()
        #expect(readers.reads == 0 && readers.hardwareReads == 0)
        #expect(!model.hasSample)
        #expect(model.hardware.chip.isEmpty)
        #expect(model.diagnosticReport == MetricsModel.readingsUnavailable)
        #expect(MenuBarText.readout(.cpu, access: model.hasAccess, hasSample: model.hasSample, cpu: model.cpu, memory: model.memory) == nil)
        model.stop()
    }

    @Test("A grant reads at once; the sample, the readout and the report follow")
    func grantCollects() {
        let model = makeModel()
        access.state = .trial(daysLeft: 3)
        model.tick()
        #expect(readers.reads == 1 && readers.hardwareReads == 1)
        #expect(model.hasSample)
        #expect(model.cpu.total == 42)
        #expect(model.processTree.first?.sample.name == "TestApp")
        #expect(model.diagnosticReport.contains("TestApp") || model.diagnosticReport.contains("Test M1"))
        #expect(MenuBarText.readout(.cpu, access: model.hasAccess, hasSample: model.hasSample, cpu: model.cpu, memory: model.memory) == "42%")
        model.tick()
        #expect(readers.reads == 2 && readers.hardwareReads == 1) // hardware once
    }

    @Test("Access lost between ticks: the next tick reads nothing and drops the sample")
    func lapseDropsTheSample() {
        let model = makeModel()
        access.state = .trial(daysLeft: 1)
        model.tick()
        #expect(model.hasSample)
        access.state = .trialEnded // no `stop` from the app yet: the deadline timer has not fired
        // The exports refuse before any tick, on the current access.
        #expect(model.diagnosticReport == MetricsModel.readingsUnavailable)
        #expect(MenuBarText.readout(.cpu, access: model.hasAccess, hasSample: model.hasSample, cpu: model.cpu, memory: model.memory) == nil)
        model.tick()
        #expect(readers.reads == 1)
        #expect(!model.hasSample)
        #expect(model.cpu.total == 0)
        #expect(model.processTree.isEmpty && model.cpuHistory.isEmpty && model.flightRecorder.isEmpty)
        #expect(model.diagnosticReport == MetricsModel.readingsUnavailable)
        // Granted again: a fresh read, not the old sample.
        access.state = .licensed
        model.tick()
        #expect(readers.reads == 2)
        #expect(model.hasSample)
    }

    @Test("Copy Diagnostics keeps version, login and flavour, and refuses the readings while restricted")
    func diagnosticsExport() {
        let model = makeModel()
        let restricted = Diagnostics.text(model: model, loginStatus: "enabled")
        #expect(restricted.contains("Open at login: enabled"))
        #expect(restricted.contains("Licensing:"))
        #expect(restricted.contains("Readings: off (license)"))
        #expect(restricted.contains(MetricsModel.readingsUnavailable))
        #expect(!restricted.contains("Test M1") && !restricted.contains("TestApp") && !restricted.contains("CPU"))
        access.state = .trial(daysLeft: 2)
        model.tick()
        let allowed = Diagnostics.text(model: model, loginStatus: "enabled")
        #expect(allowed.contains("Readings: allowed"))
        #expect(allowed.contains("Test M1"))
        // A lapse after the sample was taken: the export refuses at once.
        access.state = .revoked
        let afterLapse = Diagnostics.text(model: model, loginStatus: "enabled")
        #expect(afterLapse.contains("Readings: off (license)"))
        #expect(!afterLapse.contains("Test M1"))
    }
}

/// The whole chain as the app wires it, without the app: the real
/// `LicenseManager` with Hertz's values and fakes publishes snapshots to a
/// box (the controller's feed), `LicenseStatus` and the metrics model ask
/// the projection of that snapshot to the fake clocks on every read. The
/// assertions are the outputs — readout, dashboard card, collection,
/// export — for each restricted state and across deadlines no timer
/// delivered.
@Suite("Licensing enforcement")
@MainActor
struct EnforcementTests {
    static let paid = "pdt_0NniFBM9HoAzUZgUkMhz2"

    let clock = FakeClock()
    let client = FakeClient()
    let store = MemoryStore()
    let journal = MemoryJournal()
    let trialStore = MemoryTrialStore()
    let registry = FakeRegistry()
    let device = FakeDevice()
    let feed = SnapshotBox()
    let readers = CountingReaders()
    let status = LicenseStatus()

    /// Everything the delegate wires, on fakes: the manager loaded and its
    /// launch check run, the status and the model bound to the projection.
    func attach() async -> (LicenseManager, MetricsModel) {
        let clock = self.clock
        let feed = self.feed
        let manager = LicenseManager(
            appID: Licensing.appID, products: LicenseProducts(paid: [Self.paid]), client: client, store: store, journal: journal,
            trialStore: trialStore, registry: registry, device: device, trialTiming: Licensing.trialTiming,
            now: { clock.now }, uptime: { clock.uptime }
        )
        await manager.setOnChange { feed.snapshot = $0 }
        await manager.load()
        await manager.checkOnLaunch()
        let project: () -> LicenseState = { feed.snapshot.state(now: clock.now, uptime: clock.uptime) }
        status.bind(
            access: { project().isFeatureEnabled },
            state: { project() },
            restriction: { LicenseRestriction.card(for: project(), storageError: feed.snapshot.storageError != nil, trialStorageError: feed.snapshot.trialStorageError != nil) },
            badge: { LicenseBadge.label(for: project(), appName: Licensing.appName, storageError: feed.snapshot.storageError != nil, trialStorageError: feed.snapshot.trialStorageError != nil) },
            canBuy: true
        )
        let model = MetricsModel(readers: { readers.readers })
        model.access = { project().isFeatureEnabled }
        return (manager, model)
    }

    func trialRecord(elapsed: TimeInterval, registered: Bool = true) -> TrialRecord {
        TrialRecord(startedAt: clock.now.addingTimeInterval(-elapsed), lastSeenAt: clock.now, registered: registered)
    }

    func paidRecord(lastSuccessAge age: TimeInterval) -> LicenseRecord {
        LicenseRecord(
            licenseKey: "KEY", instanceID: "inst_1", productID: Self.paid,
            activatedAt: clock.now.addingTimeInterval(-30 * FakeClock.day), lastSuccessAt: clock.now.addingTimeInterval(-age)
        )
    }

    /// What every restricted state must look like at the outputs.
    func expectRestricted(_ model: MetricsModel, title: String, readsBefore: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!status.hasAccess(), sourceLocation: sourceLocation)
        #expect(status.restriction()?.title == title, sourceLocation: sourceLocation)
        #expect(status.badge()?.tone == .attention, sourceLocation: sourceLocation)
        model.tick()
        #expect(readers.reads == readsBefore, "no read while restricted", sourceLocation: sourceLocation)
        #expect(!model.hasSample, sourceLocation: sourceLocation)
        #expect(MenuBarText.readout(.cpu, access: status.hasAccess(), hasSample: model.hasSample, cpu: model.cpu, memory: model.memory) == nil, sourceLocation: sourceLocation)
        #expect(model.diagnosticReport == MetricsModel.readingsUnavailable, sourceLocation: sourceLocation)
        #expect(!Diagnostics.text(model: model, loginStatus: "enabled").contains("Test M1"), sourceLocation: sourceLocation)
    }

    // MARK: Each restricted state, at the outputs

    @Test("13. Ended trial at launch: pulse alone, the card, no read, no export")
    func trialEnded() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day + 60)
        let (_, model) = await attach()
        model.start()
        expectRestricted(model, title: "Your free trial has ended", readsBefore: 0)
        #expect(status.restriction()?.actions == [.buy, .enterKey])
        #expect(registry.devices.isEmpty && client.calls.isEmpty)
        model.stop()
    }

    @Test("17. Unreadable trial record: storage error card, no read, no new trial", arguments: [LicenseStoreError.unavailable("locked"), .corrupt])
    func trialStorageError(error: LicenseStoreError) async {
        trialStore.record = trialRecord(elapsed: 3600, registered: false)
        trialStore.readError = error
        let (manager, model) = await attach()
        expectRestricted(model, title: "Can’t read or save the free trial record", readsBefore: 0)
        #expect(status.restriction()?.actions.first == .tryAgain)
        #expect(trialStore.saves.isEmpty && registry.devices.isEmpty)
        // Readable again ("Try again"): the readings come back.
        trialStore.readError = nil
        await manager.tick(wake: true)
        #expect(status.hasAccess())
        model.tick()
        #expect(readers.reads == 1 && model.hasSample)
    }

    @Test("Unregistered trial past its offline limit: connect to continue")
    func trialNeedsConnection() async {
        trialStore.record = trialRecord(elapsed: 25 * 3600, registered: false)
        registry.result = .unreachable
        let (_, model) = await attach()
        expectRestricted(model, title: "Connect to the internet to continue your free trial", readsBefore: 0)
        #expect(status.restriction()?.actions == [.tryAgain, .buy, .enterKey])
    }

    @Test("14. Clock behind at launch: held off, nothing saved, back with the day that was left")
    func trialClockBehind() async {
        trialStore.record = trialRecord(elapsed: 2 * FakeClock.day)
        clock.advance(-5 * FakeClock.day)
        let (manager, model) = await attach()
        expectRestricted(model, title: "Your Mac’s clock is behind", readsBefore: 0)
        #expect(trialStore.saves.isEmpty)
        // The wall clock looks right again: still held until the manager
        // observes it — a projection never releases a held clock.
        clock.now = FakeClock.start.addingTimeInterval(-30 * 60)
        #expect(!status.hasAccess())
        model.tick()
        #expect(readers.reads == 0)
        await manager.tick()
        #expect(status.state() == .trial(daysLeft: 1))
        model.tick()
        #expect(readers.reads == 1 && model.hasSample)
    }

    @Test("8. Licensed, 8 days without a check and offline: check required, no Buy")
    func checkRequired() async {
        store.record = paidRecord(lastSuccessAge: 8 * FakeClock.day)
        client.validation = .unreachable
        let (_, model) = await attach()
        expectRestricted(model, title: "Connect to the internet to verify your license", readsBefore: 0)
        #expect(status.restriction()?.actions == [.tryAgain, .enterKey])
    }

    @Test("10. Licensed, then valid: false: revoked at once, the sample dropped")
    func revoked() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .valid(serverDate: clock.now)
        let (manager, model) = await attach()
        #expect(status.hasAccess())
        model.tick()
        #expect(readers.reads == 1 && model.hasSample)
        // Refunded meanwhile: the next daily check answers valid: false.
        client.validation = .invalid
        clock.advance(LicensePolicy.checkInterval + 1)
        await manager.tick()
        expectRestricted(model, title: "This license is no longer active on this Mac", readsBefore: 1)
        #expect(status.restriction()?.actions == [.enterKey, .buy])
    }

    // MARK: Deadlines nobody delivered

    @Test("A trial that ends between ticks: the next tick refuses, before any deadline callback")
    func trialEndsWithoutACallback() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        let (_, model) = await attach()
        #expect(status.hasAccess())
        #expect(status.badge()?.text == "Free trial · less than a day left")
        model.tick()
        #expect(readers.reads == 1 && model.hasSample)
        // Two minutes pass. No manager tick, no timer, no publish: the
        // projection alone decides.
        clock.advance(120)
        expectRestricted(model, title: "Your free trial has ended", readsBefore: 1)
    }

    @Test("28. A frozen wall clock does not extend the trial: monotonic time ends it")
    func monotonicTimeEndsTheTrial() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        let (_, model) = await attach()
        model.tick()
        #expect(model.hasSample)
        clock.uptime += 120 // the wall clock stands still
        expectRestricted(model, title: "Your free trial has ended", readsBefore: 1)
    }

    @Test("20. An unregistered trial reaches 24 h between ticks: off until the registry answers")
    func offlineLimitWithoutACallback() async {
        trialStore.record = trialRecord(elapsed: 24 * 3600 - 60, registered: false)
        registry.result = .unreachable
        let (manager, model) = await attach()
        #expect(status.hasAccess())
        model.tick()
        clock.advance(120)
        expectRestricted(model, title: "Connect to the internet to continue your free trial", readsBefore: 1)
        // The registry answers with the same start: the trial resumes with what is left.
        registry.result = .registered(startedAt: clock.now.addingTimeInterval(-(24 * 3600 + 60)), now: clock.now)
        await manager.tick(wake: true)
        #expect(status.state() == .trial(daysLeft: 2))
        model.tick()
        #expect(readers.reads == 2 && model.hasSample)
    }

    @Test("Grace ends between ticks: check required, before any deadline callback")
    func graceEndsWithoutACallback() async {
        store.record = paidRecord(lastSuccessAge: LicensePolicy.graceDuration - 60)
        client.validation = .unreachable
        let (_, model) = await attach()
        #expect(status.hasAccess())
        #expect(status.badge()?.text.hasPrefix("Connect to the internet within") == true)
        model.tick()
        clock.advance(120)
        expectRestricted(model, title: "Connect to the internet to verify your license", readsBefore: 1)
    }

    @Test("1. Activation during an ended trial turns the readings on at the next read")
    func activationRestores() async {
        trialStore.record = trialRecord(elapsed: 4 * FakeClock.day)
        client.activation = .activated(Activation(instanceID: "inst_1", productID: Self.paid, productName: "Hertz", createdAt: clock.now, serverDate: clock.now))
        let (manager, model) = await attach()
        expectRestricted(model, title: "Your free trial has ended", readsBefore: 0)
        #expect(await manager.activate(key: "HERTZ-KEY") == .activated)
        #expect(status.hasAccess())
        #expect(status.restriction() == nil && status.badge() == nil)
        #expect(status.state() == .licensed)
        model.tick()
        #expect(readers.reads == 1 && model.hasSample)
        #expect(MenuBarText.readout(.cpu, access: status.hasAccess(), hasSample: model.hasSample, cpu: model.cpu, memory: model.memory) == "42%")
    }
}

#if OPENAPPS_LICENSING
/// The same deadlines through the real `LicenseController`: its `state`
/// is the projection at the moment it is asked, so the model and the
/// status bound to it refuse before its deadline timer runs.
@Suite("License controller enforcement")
@MainActor
struct LicenseControllerEnforcementTests {
    let clock = FakeClock()
    let trialStore = MemoryTrialStore()
    let readers = CountingReaders()

    func makeController() -> LicenseController {
        let clock = self.clock
        let manager = LicenseManager(
            appID: Licensing.appID, products: LicenseProducts(paid: [EnforcementTests.paid]), client: FakeClient(), store: MemoryStore(),
            journal: MemoryJournal(), trialStore: trialStore, registry: FakeRegistry(), device: FakeDevice(),
            trialTiming: Licensing.trialTiming, now: { clock.now }, uptime: { clock.uptime }
        )
        return LicenseController(manager: manager, now: { clock.now }, uptime: { clock.uptime })
    }

    /// The controller's snapshot feed hops to the main queue; let it land.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func startsRestrictedUntilStorageAnswers() {
        let controller = makeController()
        #expect(controller.state == .trialUnavailable)
        #expect(!controller.isFeatureEnabled)
        #expect(controller.badge?.text == "Starting your free trial…")
        #expect(controller.restriction?.title == "Starting your free trial…")
        #expect(controller.freshInstall == nil)
        #expect(LicenseController.trialText(daysLeft: 2) == "Free trial: 2 days left")
        #expect(LicenseController.trialText(daysLeft: 1) == "Free trial: less than a day left")
    }

    @Test("The trial ends between ticks: the controller, the status and the model refuse without its timer")
    func trialEndsWithoutTheDeadlineTimer() async {
        trialStore.record = TrialRecord(startedAt: clock.now.addingTimeInterval(-(3 * FakeClock.day - 60)), lastSeenAt: clock.now, registered: true)
        let controller = makeController()
        await controller.attach()
        await settle()
        #expect(controller.state == .trial(daysLeft: 1))
        #expect(controller.isFeatureEnabled)

        let status = LicenseStatus()
        status.bind(
            access: { [weak controller] in controller?.isFeatureEnabled ?? false },
            state: { [weak controller] in controller?.state },
            restriction: { [weak controller] in controller?.restriction },
            badge: { [weak controller] in controller?.badge },
            canBuy: true
        )
        let model = MetricsModel(readers: { readers.readers })
        model.access = { [weak controller] in controller?.isFeatureEnabled ?? false }
        model.tick()
        #expect(readers.reads == 1 && model.hasSample)
        #expect(status.badge()?.text == "Free trial · less than a day left")

        clock.advance(120) // no timer fires, no snapshot arrives
        #expect(controller.state == .trialEnded)
        #expect(!controller.isFeatureEnabled)
        #expect(!status.hasAccess())
        #expect(status.restriction()?.title == "Your free trial has ended")
        model.tick()
        #expect(readers.reads == 1)
        #expect(!model.hasSample)
        #expect(model.diagnosticReport == MetricsModel.readingsUnavailable)
        #expect(MenuBarText.readout(.cpu, access: status.hasAccess(), hasSample: model.hasSample, cpu: model.cpu, memory: model.memory) == nil)
    }
}
#endif

/// The dashboard's export actions as the views hold them — closures bound
/// when the view was built, invoked later at a click — with the clipboard
/// and the Finder replaced by sinks. What reaches a sink is decided at the
/// click, from the access and the sample of that moment, never from what
/// the view captured.
@Suite("Dashboard export actions")
@MainActor
struct ExportActionTests {
    final class Sinks {
        var copied: [String] = []
        var revealed: [URL] = []
    }

    let readers = CountingReaders()
    let access = StateBox(.trial(daysLeft: 2))
    let sinks = Sinks()

    /// The model, and the actions exactly as `DashboardView` builds them.
    func render() -> (MetricsModel, copyReport: () -> MetricsModel.Export, copyBlockers: () -> MetricsModel.Export,
                      copyGroup: (pid_t) -> MetricsModel.Export, revealGroup: (pid_t) -> MetricsModel.Export,
                      copyProcess: (pid_t) -> MetricsModel.Export, revealProcess: (pid_t) -> MetricsModel.Export) {
        let model = MetricsModel(readers: { readers.readers })
        model.access = { access.state.isFeatureEnabled }
        model.clipboard = { sinks.copied.append($0) }
        model.reveal = { sinks.revealed.append($0) }
        model.tick()
        return (model, model.copyDiagnosticReport, model.copySleepBlockersReport,
                model.copySleepBlockerDetails(pid:), model.revealSleepBlocker(pid:),
                model.copyProcessDetails(pid:), model.revealProcess(pid:))
    }

    @Test("While allowed, every action exports the current sample")
    func allowedActionsExport() {
        let (model, copyReport, copyBlockers, copyGroup, revealGroup, copyProcess, revealProcess) = render()
        #expect(model.hasSample)
        #expect(copyReport() == .done("Copied the diagnostic snapshot"))
        #expect(sinks.copied.last?.contains("Test M1") == true)
        #expect(copyBlockers() == .done("Copied the sleep blocker report"))
        #expect(sinks.copied.last?.contains("Keepr") == true)
        #expect(copyGroup(20) == .done("Copied Keepr"))
        #expect(revealGroup(20) == .done("Revealed Keepr in Finder"))
        #expect(sinks.revealed.last?.path == "/Applications/Keepr.app")
        #expect(copyProcess(10) == .done("Copied TestApp"))
        #expect(sinks.copied.last == "TestApp\tpid 10\t/Applications/TestApp.app")
        #expect(revealProcess(10) == .done("Revealed TestApp in Finder"))
        #expect(sinks.revealed.last?.path == "/Applications/TestApp.app")
    }

    @Test("Rendered while allowed, clicked after the lapse with no tick and no rerender: nothing but the refusal reaches the sinks")
    func lapseBetweenRenderAndClick() {
        let (model, copyReport, copyBlockers, copyGroup, revealGroup, copyProcess, revealProcess) = render()
        #expect(model.hasSample) // the old sample is still held: no tick has run
        access.state = .trialEnded
        let copiedBefore = sinks.copied.count
        #expect(copyReport() == .refused)
        #expect(copyBlockers() == .refused)
        #expect(copyGroup(20) == .refused)
        #expect(revealGroup(20) == .refused)
        #expect(copyProcess(10) == .refused)
        #expect(revealProcess(10) == .refused)
        #expect(sinks.copied.count == copiedBefore + 4)
        #expect(sinks.copied.suffix(4).allSatisfy { $0 == MetricsModel.exportRefused })
        #expect(sinks.revealed.isEmpty)
        #expect(model.hasSample, "the actions refuse on access alone; the tick clears the sample")
        // The card's note names the refusal.
        #expect(MetricsModel.Export.refused.note == MetricsModel.exportRefused)
    }

    @Test("A row whose process left the sample copies and reveals nothing, even while allowed")
    func goneRowsExportNothing() {
        let (model, _, _, copyGroup, revealGroup, copyProcess, revealProcess) = render()
        readers.blocker = nil
        model.tick() // the next sample has no blocker; the old row's pid stays in the view
        let copiedBefore = sinks.copied.count
        #expect(copyGroup(20) == .gone)
        #expect(revealGroup(20) == .gone)
        #expect(copyProcess(99) == .gone)
        #expect(revealProcess(99) == .gone)
        #expect(sinks.copied.count == copiedBefore)
        #expect(sinks.revealed.isEmpty)
    }

    @Test("Copy Diagnostics after the lapse sends no reading to the clipboard")
    func settingsCopyAfterLapse() {
        let (model, _, _, _, _, _, _) = render()
        access.state = .revoked
        model.clipboard(Diagnostics.text(model: model, loginStatus: "on"))
        let text = sinks.copied.last ?? ""
        #expect(text.contains("Readings: off (license)"))
        #expect(text.contains(MetricsModel.readingsUnavailable))
        #expect(!text.contains("Test M1") && !text.contains("TestApp") && !text.contains("Keepr"))
    }

    @Test("Through the real manager: a report action captured under the trial refuses once the trial has ended, with no tick")
    func realDeadlineBetweenRenderAndClick() async {
        let harness = EnforcementTests()
        harness.trialStore.record = harness.trialRecord(elapsed: 3 * FakeClock.day - 60)
        let (_, model) = await harness.attach()
        model.clipboard = { sinks.copied.append($0) }
        model.tick()
        let copyReport = model.copyDiagnosticReport // the view's closure, built while allowed
        #expect(copyReport() == .done("Copied the diagnostic snapshot"))
        harness.clock.advance(120) // no manager tick, no model tick, no rerender
        #expect(copyReport() == .refused)
        #expect(sinks.copied.last == MetricsModel.exportRefused)
        #expect(!sinks.copied.last!.contains("Test M1"))
    }
}
