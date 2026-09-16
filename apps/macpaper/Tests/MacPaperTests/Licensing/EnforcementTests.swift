import Foundation
@testable import MacPaper
import MacPaperCore
import OpenAppsLicensing
import Testing

/// The whole chain as the app wires it, without the app: the real
/// `LicenseManager` with macPaper's values and fakes publishes snapshots to
/// a box (the controller's feed), `LicenseStatus` asks the projection of
/// that snapshot to the fake clocks on every read, and the model asks the
/// status at every action. The assertions are the outputs — the card, the
/// badge, the desktop, the export folder, the draft — for each restricted
/// state and across deadlines no timer delivered.
@Suite("Licensing enforcement")
@MainActor
struct EnforcementTests {
    /// macPaper's Dodo product in test mode (the Dodo products artifact).
    static let paid = "pdt_0NnitBSdSZZTDSnKu7j88"

    let clock = FakeClock()
    let client = FakeClient()
    let store = MemoryStore()
    let journal = MemoryJournal()
    let trialStore = MemoryTrialStore()
    let registry = FakeRegistry()
    let device = FakeDevice()
    let feed = SnapshotBox()
    let harness = AppModelTests.Harness()

    var status: LicenseStatus { harness.license }
    var model: AppModel { harness.model }

    /// Everything the delegate wires, on fakes: the manager loaded and its
    /// launch check run, the status the model holds bound to the projection.
    func attach() async -> LicenseManager {
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
        harness.preferences.sameOnAllDisplays = true
        return manager
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

    /// What every restricted state must look like at the outputs: the card
    /// and the badge say so, and every action — Apply, Shuffle, the
    /// scheduled shuffle, Export, a new seed, a typed seed — changes nothing
    /// on the desktop, in the export folder or in the draft.
    func expectRestricted(title: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(!status.hasAccess(), sourceLocation: sourceLocation)
        #expect(status.restriction()?.title == title, sourceLocation: sourceLocation)
        #expect(status.badge()?.tone == .attention, sourceLocation: sourceLocation)
        #expect(!model.canAct, sourceLocation: sourceLocation)
        let desktopBefore = harness.desktop.calls.count
        let exportsBefore = harness.exporter.exported.count
        let draftBefore = model.draft
        model.apply()
        model.apply(.allDisplays)
        model.shuffle()
        model.scheduledShuffle()
        model.export(.png)
        model.export(.svg)
        model.reseed()
        #expect(model.setSeed("42") == .refused, sourceLocation: sourceLocation)
        model.generatorKind = model.generatorKind == .solid ? .mesh : .solid
        model.edited.grain = 0.77
        await harness.settle()
        #expect(harness.desktop.calls.count == desktopBefore, "nothing applied while restricted", sourceLocation: sourceLocation)
        #expect(harness.exporter.exported.count == exportsBefore, "nothing exported while restricted", sourceLocation: sourceLocation)
        #expect(model.draft == draftBefore, "no new document while restricted", sourceLocation: sourceLocation)
        #expect(model.status == StatusLine(text: AppModel.restrictedMessage, tone: .error), sourceLocation: sourceLocation)
        model.clearStatus()
    }

    /// The feature runs: Apply reaches the desktop and Export the folder.
    func expectAllowed(sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(status.hasAccess(), sourceLocation: sourceLocation)
        #expect(status.restriction() == nil, sourceLocation: sourceLocation)
        #expect(model.canAct, sourceLocation: sourceLocation)
        let desktopBefore = harness.desktop.calls.count
        let exportsBefore = harness.exporter.exported.count
        model.apply()
        await harness.settle()
        model.export(.svg)
        await harness.settle()
        #expect(harness.desktop.calls.count == desktopBefore + 2, sourceLocation: sourceLocation)
        #expect(harness.exporter.exported.count == exportsBefore + 1, sourceLocation: sourceLocation)
    }

    // MARK: Each restricted state, at the outputs

    @Test("13. Ended trial at launch: the card, no apply, no export, no network calls")
    func trialEnded() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day + 60)
        _ = await attach()
        await expectRestricted(title: "Your free trial has ended")
        #expect(status.restriction()?.actions == [.buy, .enterKey])
        #expect(status.badge()?.text == "Trial ended")
        #expect(registry.devices.isEmpty && client.calls.isEmpty)
        harness.tearDown()
    }

    @Test("17. Unreadable trial record: storage error card, nothing applied, no new trial", arguments: [LicenseStoreError.unavailable("locked"), .corrupt])
    func trialStorageError(error: LicenseStoreError) async {
        trialStore.record = trialRecord(elapsed: 3600, registered: false)
        trialStore.readError = error
        let manager = await attach()
        await expectRestricted(title: "Can’t read or save the free trial record")
        #expect(status.restriction()?.actions.first == .tryAgain)
        #expect(trialStore.saves.isEmpty && registry.devices.isEmpty)
        // Readable again ("Try again"): the generator comes back.
        trialStore.readError = nil
        await manager.tick(wake: true)
        await expectAllowed()
        harness.tearDown()
    }

    @Test("Unregistered trial past its offline limit: connect to continue")
    func trialNeedsConnection() async {
        trialStore.record = trialRecord(elapsed: 25 * 3600, registered: false)
        registry.result = .unreachable
        _ = await attach()
        await expectRestricted(title: "Connect to the internet to continue your free trial")
        #expect(status.restriction()?.actions == [.tryAgain, .buy, .enterKey])
        harness.tearDown()
    }

    @Test("14. Clock behind at launch: held off, nothing saved, back with the day that was left")
    func trialClockBehind() async {
        trialStore.record = trialRecord(elapsed: 2 * FakeClock.day)
        clock.advance(-5 * FakeClock.day)
        let manager = await attach()
        await expectRestricted(title: "Your Mac’s clock is behind")
        #expect(trialStore.saves.isEmpty)
        // The wall clock looks right again: still held until the manager
        // observes it — a projection never releases a held clock.
        clock.now = FakeClock.start.addingTimeInterval(-30 * 60)
        #expect(!status.hasAccess())
        model.apply()
        await harness.settle()
        #expect(harness.desktop.calls.isEmpty)
        await manager.tick()
        #expect(status.state() == .trial(daysLeft: 1))
        await expectAllowed()
        harness.tearDown()
    }

    @Test("8. Licensed, 8 days without a check and offline: check required, no Buy")
    func checkRequired() async {
        store.record = paidRecord(lastSuccessAge: 8 * FakeClock.day)
        client.validation = .unreachable
        _ = await attach()
        await expectRestricted(title: "Connect to the internet to verify your license")
        #expect(status.restriction()?.actions == [.tryAgain, .enterKey])
        harness.tearDown()
    }

    @Test("10. Licensed, then valid: false: revoked at once")
    func revoked() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .valid(serverDate: clock.now)
        let manager = await attach()
        await expectAllowed()
        // Refunded meanwhile: the next daily check answers valid: false.
        client.validation = .invalid
        clock.advance(LicensePolicy.checkInterval + 1)
        await manager.tick()
        await expectRestricted(title: "This license is no longer active on this Mac")
        #expect(status.restriction()?.actions == [.enterKey, .buy])
        harness.tearDown()
    }

    // MARK: Deadlines nobody delivered

    @Test("A trial that ends between ticks: the next click refuses, before any deadline callback")
    func trialEndsWithoutACallback() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        #expect(status.badge()?.text == "Free trial · less than a day left")
        await expectAllowed()
        // Two minutes pass. No manager tick, no timer, no publish: the
        // projection alone decides.
        clock.advance(120)
        await expectRestricted(title: "Your free trial has ended")
        harness.tearDown()
    }

    @Test("28. A frozen wall clock does not extend the trial: monotonic time ends it")
    func monotonicTimeEndsTheTrial() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        await expectAllowed()
        clock.uptime += 120 // the wall clock stands still
        await expectRestricted(title: "Your free trial has ended")
        harness.tearDown()
    }

    @Test("20. An unregistered trial reaches 24 h between ticks: off until the registry answers")
    func offlineLimitWithoutACallback() async {
        trialStore.record = trialRecord(elapsed: 24 * 3600 - 60, registered: false)
        registry.result = .unreachable
        let manager = await attach()
        await expectAllowed()
        clock.advance(120)
        await expectRestricted(title: "Connect to the internet to continue your free trial")
        // The registry answers with the same start: the trial resumes with what is left.
        registry.result = .registered(startedAt: clock.now.addingTimeInterval(-(24 * 3600 + 60)), now: clock.now)
        await manager.tick(wake: true)
        #expect(status.state() == .trial(daysLeft: 2))
        await expectAllowed()
        harness.tearDown()
    }

    @Test("Grace ends between ticks: check required, before any deadline callback")
    func graceEndsWithoutACallback() async {
        store.record = paidRecord(lastSuccessAge: LicensePolicy.graceDuration - 60)
        client.validation = .unreachable
        _ = await attach()
        #expect(status.badge()?.text.hasPrefix("Connect to the internet within") == true)
        await expectAllowed()
        clock.advance(120)
        await expectRestricted(title: "Connect to the internet to verify your license")
        harness.tearDown()
    }

    @Test("1. Activation during an ended trial turns the generator on at the next click")
    func activationRestores() async {
        trialStore.record = trialRecord(elapsed: 4 * FakeClock.day)
        client.activation = .activated(Activation(instanceID: "inst_1", productID: Self.paid, productName: "macPaper", createdAt: clock.now, serverDate: clock.now))
        let manager = await attach()
        await expectRestricted(title: "Your free trial has ended")
        #expect(await manager.activate(key: "MACPAPER-KEY") == .activated)
        #expect(status.restriction() == nil && status.badge() == nil)
        #expect(status.state() == .licensed)
        await expectAllowed()
        harness.tearDown()
    }

    @Test("The scheduled shuffle asks the projection too: nothing fires after the trial ended")
    func scheduledShuffleAfterTheDeadline() async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        model.scheduledShuffle()
        await harness.settle()
        #expect(harness.desktop.calls.count == 2, "two displays, same on all")
        model.clearStatus()
        clock.advance(120)
        model.scheduledShuffle()
        await harness.settle()
        #expect(harness.desktop.calls.count == 2)
        #expect(model.status == nil, "a timer's shuffle says nothing; the panel's card does")
        harness.tearDown()
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

        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.license.bind(
            access: { [weak controller] in controller?.isFeatureEnabled ?? false },
            state: { [weak controller] in controller?.state },
            restriction: { [weak controller] in controller?.restriction },
            badge: { [weak controller] in controller?.badge },
            canBuy: true
        )
        h.model.apply()
        await h.settle()
        #expect(h.desktop.calls.count == 2, "two displays, same on all")
        #expect(h.license.badge()?.text == "Free trial · less than a day left")

        clock.advance(120) // no timer fires, no snapshot arrives
        #expect(controller.state == .trialEnded)
        #expect(!controller.isFeatureEnabled)
        #expect(!h.license.hasAccess())
        #expect(h.license.restriction()?.title == "Your free trial has ended")
        h.model.apply()
        h.model.export(.png)
        await h.settle()
        #expect(h.desktop.calls.count == 2 && h.exporter.exported.isEmpty)
        #expect(h.model.status?.text == AppModel.restrictedMessage)
    }
}
#endif
