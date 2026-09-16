import Foundation
@testable import OpenNotes
import OpenAppsLicensing
import Testing

/// A handful of LICENSING.md's shared cases run through the real package
/// manager with OpenNotes' values (`Licensing.appID`, its paid product) and
/// fake stores and clients, then mapped to what OpenNotes shows. The package
/// tests the rules; this tests the wiring: the id, the product check, the
/// device hash and the restriction the UI derives from each outcome.
///
/// Named `LicensingWiringTests` (not `WiringTests`, as in macPaper) because
/// `AppModelTests.swift` already declares a `WiringTests` XCTestCase in this
/// module, and Swift does not allow two top-level types of the same name.
@Suite("Licensing wiring")
@LicenseActor
struct LicensingWiringTests {
    /// OpenNotes' Dodo product in test mode.
    nonisolated static let paid = "pdt_0NnjxPRw1V6N34ObK6jzN"
    static let other = "pdt_hertz_PAID"
    nonisolated static let products = LicenseProducts(paid: [paid])

    let clock = FakeClock()
    let client = FakeClient()
    let store = MemoryStore()
    let journal = MemoryJournal()
    let trialStore = MemoryTrialStore()
    let registry = FakeRegistry()
    let device = FakeDevice()

    init() {
        // By default this Mac's trial ended long ago and is registered, so
        // the license cases start from TrialEnded with no registry calls.
        trialStore.record = TrialRecord(startedAt: FakeClock.start.addingTimeInterval(-10 * FakeClock.day), registered: true)
    }

    /// The manager as `AppDelegate` builds it, with fakes for the clients
    /// and stores, read as the app does on start.
    func makeManager() -> LicenseManager {
        let clock = self.clock
        let manager = LicenseManager(
            appID: Licensing.appID, products: Self.products, client: client, store: store, journal: journal,
            trialStore: trialStore, registry: registry, device: device, trialTiming: Licensing.trialTiming,
            now: { clock.now }, uptime: { clock.uptime }
        )
        manager.load()
        return manager
    }

    func activation(_ product: String, name: String = "OpenNotes", instance: String = "inst_1") -> Activation {
        Activation(instanceID: instance, productID: product, productName: name, createdAt: clock.now, serverDate: clock.now)
    }

    func trialRecord(elapsed: TimeInterval, registered: Bool = true) -> TrialRecord {
        TrialRecord(startedAt: clock.now.addingTimeInterval(-elapsed), lastSeenAt: clock.now, registered: registered)
    }

    /// What the panel does with the manager's state.
    func restriction(_ manager: LicenseManager) -> LicenseRestriction? {
        LicenseRestriction.card(for: manager.state, storageError: manager.storageError != nil, trialStorageError: manager.trialStorageError != nil)
    }

    @Test("1. OpenNotes' paid key activates and is stored, from Trial or TrialEnded", arguments: [false, true])
    func case1_paidKeyActivates(duringTrial: Bool) async {
        if duringTrial { trialStore.record = trialRecord(elapsed: FakeClock.day) }
        let trialBefore = trialStore.record
        client.activation = .activated(activation(Self.paid))
        let manager = makeManager()
        #expect(manager.state == (duringTrial ? .trial(daysLeft: 2) : .trialEnded))
        #expect((restriction(manager) == nil) == duringTrial)
        let message = await manager.activate(key: " OPENNOTES-KEY\n")
        #expect(message == .activated)
        #expect(message.text(appName: Licensing.appName) == "OpenNotes is licensed on this Mac.")
        #expect(manager.state == .licensed)
        #expect(restriction(manager) == nil)
        #expect(LicenseBadge.label(for: manager.state, appName: Licensing.appName) == nil)
        #expect(store.record?.productID == Self.paid)
        #expect(store.record?.licenseKey == "OPENNOTES-KEY")
        #expect(client.calls == [.activate(key: "OPENNOTES-KEY", name: "Mac")])
        #expect(trialStore.record == trialBefore)
    }

    @Test("2. Another app's key is refused with OpenNotes named, deactivated again, nothing saved")
    func case2_foreignKey() async {
        client.activation = .activated(activation(Self.other, name: "Hertz", instance: "inst_x"))
        let manager = makeManager()
        let message = await manager.activate(key: "HZ-KEY")
        #expect(message == .wrongProduct(productName: "Hertz"))
        #expect(message.text(appName: Licensing.appName) == "This key is for Hertz, not OpenNotes.")
        #expect(store.record == nil)
        #expect(manager.state == .trialEnded)
        #expect(restriction(manager)?.actions == [.buy, .enterKey])
        #expect(client.calls == [.activate(key: "HZ-KEY", name: "Mac"), .deactivate(instance: "inst_x")])
    }

    @Test("5. An activation timeout saves nothing and keeps writing off")
    func case5_timeout() async {
        client.activation = .unreachable
        let manager = makeManager()
        let message = await manager.activate(key: "OPENNOTES-KEY")
        #expect(message == .unreachable)
        #expect(message.text(appName: Licensing.appName).hasPrefix("Couldn’t reach the license service"))
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
        #expect(restriction(manager)?.title == "Your free trial has ended")
        #expect(!manager.isFeatureEnabled)
    }

    @Test("13. A registered trial past 3 days has ended at launch, with no network calls", arguments: [false, true])
    func case13_endedTrialAtLaunch(online: Bool) async {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day + 60)
        registry.result = online ? .registered(startedAt: clock.now, now: clock.now) : .unreachable
        let manager = makeManager()
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
        await manager.checkOnLaunch()
        await manager.tick(wake: true)
        #expect(manager.state == .trialEnded)
        #expect(registry.devices.isEmpty)
        #expect(client.calls.isEmpty)
        #expect(restriction(manager)?.actions == [.buy, .enterKey])
        #expect(LicenseBadge.label(for: manager.state, appName: Licensing.appName)?.text == "Trial ended")
    }

    @Test("17. An unreadable trial record is a storage error: no new trial, no registry call, nothing overwritten", arguments: [
        LicenseStoreError.unavailable("locked"), LicenseStoreError.corrupt,
    ])
    func case17_unreadableTrialRecord(error: LicenseStoreError) async {
        trialStore.record = trialRecord(elapsed: 12 * 3600, registered: false)
        let existing = trialStore.record
        trialStore.readError = error
        let manager = makeManager()
        #expect(manager.state == .trialUnavailable)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.trialStorageError == error)
        await manager.checkOnLaunch()
        await manager.tick()
        manager.saveTrialBeforeQuit()
        #expect(manager.state == .trialUnavailable)
        #expect(registry.devices.isEmpty)
        #expect(trialStore.saves.isEmpty)
        #expect(trialStore.record == existing)
        // The panel names the storage problem and offers a retry, not a new trial.
        let card = restriction(manager)
        #expect(card?.title == "Can’t read or save the free trial record")
        #expect(card?.actions.first == .tryAgain)
        // Readable again: the stored record decides and writing returns.
        trialStore.readError = nil
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(restriction(manager) == nil)
        #expect(registry.devices.count == 1)
    }

    @Test("18. After the records are wiped, the registry's older start ends the trial")
    func case18_wipedRegistryEndsTrial() async {
        trialStore.record = nil
        let registryNow = clock.now.addingTimeInterval(-3 * 3600)
        registry.result = .registered(startedAt: registryNow.addingTimeInterval(-4 * FakeClock.day), now: registryNow)
        let manager = makeManager()
        #expect(manager.state == .trial(daysLeft: 3)) // provisional: writing runs
        #expect(restriction(manager) == nil)
        #expect(trialStore.record?.registered == false)
        await manager.checkOnLaunch()
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
        #expect(restriction(manager)?.title == "Your free trial has ended")
        #expect(trialStore.record?.registered == true)
        #expect(trialStore.record?.startedAt == clock.now.addingTimeInterval(-4 * FakeClock.day))
        #expect(client.calls.isEmpty)
    }

    @Test("27. The registry sees OpenNotes' salted hash, never the hardware UUID or another app's hash")
    func case27_deviceHash() async {
        trialStore.record = nil
        registry.result = .registered(startedAt: clock.now, now: clock.now)
        let manager = makeManager()
        await manager.checkOnLaunch()
        let sent = registry.devices
        #expect(sent.count == 1)
        #expect(sent.first == TrialDevice.hash(app: Licensing.appID, hardwareID: device.uuid!))
        #expect(sent.first != device.uuid)
        #expect(sent.first != TrialDevice.hash(app: "hertz", hardwareID: device.uuid!))
        #expect(sent.first?.count == 64)
    }
}
