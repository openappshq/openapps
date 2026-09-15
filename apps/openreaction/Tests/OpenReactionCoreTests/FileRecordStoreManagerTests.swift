import Foundation
@testable import OpenReactionCore
import Testing

/// The manager over the real file store: what the store reports is what
/// the manager does with it. A save that landed but is not known durable
/// (`.indeterminate`) keeps the record and the activation, but a grant
/// waits: access stays with the record the store last confirmed until a
/// retried save succeeds.
@Suite("File record store with the manager")
@LicenseActor
struct FileRecordStoreManagerTests {
    typealias Sandbox = FileRecordStoreTests.Sandbox
    typealias FailingSystem = FileRecordStoreTests.FailingSystem
    typealias Fixtures = FileRecordStoreTests

    let sandbox: Sandbox
    let failing: FailingSystem
    let clock = LicensingTests.Clock()
    let client = LicensingTests.FakeClient()
    let journal = LicensingTests.MemoryJournal()
    let registry = LicensingTests.FakeRegistry()
    let device = LicensingTests.FakeDevice()

    init() {
        sandbox = Sandbox()
        failing = FailingSystem(records: sandbox.records)
    }

    /// The store the manager uses, with failures injectable.
    var store: FileRecordStore {
        FileRecordStore(appID: LicenseManager.trialAppID, device: device, baseDirectory: sandbox.root, system: failing.system)
    }

    /// The same files through the live system calls: what is really there.
    var disk: FileRecordStore {
        FileRecordStore(appID: LicenseManager.trialAppID, device: device, baseDirectory: sandbox.root)
    }

    func makeManager() -> LicenseManager {
        let clock = self.clock
        let manager = LicenseManager(
            products: LicensingTests.products, client: client, store: store, journal: journal,
            trialStore: store, registry: registry, device: device, now: { clock.now }, uptime: { clock.uptime }
        )
        manager.load()
        return manager
    }

    /// Every snapshot the manager published, for "never enabled meanwhile".
    final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [LicenseSnapshot] = []
        func append(_ snapshot: LicenseSnapshot) { lock.withLock { all.append(snapshot) } }
        func states(now: Date, uptime: TimeInterval) -> [LicenseState] { lock.withLock { all.map { $0.state(now: now, uptime: uptime) } } }
        var count: Int { lock.withLock { all.count } }
    }

    private func activation(_ instance: String) -> Activation {
        Activation(instanceID: instance, productID: LicensingTests.paid, productName: "OpenReaction", createdAt: clock.now, serverDate: clock.now)
    }

    /// An ended, registered trial, as the license cases start.
    private func endedTrial() throws {
        try disk.saveTrial(TrialRecord(startedAt: clock.now.addingTimeInterval(-10 * LicensingTests.Clock.day), registered: true))
    }

    private func paidRecord(instance: String = "inst_1", key: String = "KEY-PAID", lastSuccessAge: TimeInterval = 3600) throws {
        try disk.saveRecord(LicenseRecord(
            licenseKey: key, instanceID: instance, productID: LicensingTests.paid,
            activatedAt: clock.now.addingTimeInterval(-30 * LicensingTests.Clock.day), lastSuccessAt: clock.now.addingTimeInterval(-lastSuccessAge)
        ))
    }

    private func isIndeterminate(_ error: LicenseStoreError?) -> Bool { Fixtures.isIndeterminate(error) }

    // MARK: Case 17 over the real store

    @Test("17. A dangling trial link is a storage error: no new trial, no registry call, the link untouched")
    func aDanglingTrialLinkStartsNoTrial() async throws {
        try disk.saveTrial(Fixtures.trial) // creates the directory
        try FileManager.default.removeItem(at: sandbox.file(FileRecordStore.trialFile))
        let target = sandbox.root.appendingPathComponent("gone")
        try FileManager.default.createSymbolicLink(at: sandbox.file(FileRecordStore.trialFile), withDestinationURL: target)
        registry.result = .registered(startedAt: clock.now, now: clock.now)

        let manager = makeManager()
        #expect(manager.state == .trialUnavailable)
        #expect(!manager.isFeatureEnabled)
        #expect(Fixtures.isUnavailable(manager.trialStorageError))
        await manager.checkOnLaunch()
        await manager.tick()
        await manager.tick(wake: true)
        manager.saveTrialBeforeQuit()
        #expect(manager.state == .trialUnavailable)
        #expect(registry.devices.isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: sandbox.file(FileRecordStore.trialFile).path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try sandbox.contents() == [FileRecordStore.trialFile])

        // The link removed by hand: a positively absent record, the trial starts.
        try FileManager.default.removeItem(at: sandbox.file(FileRecordStore.trialFile))
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(try disk.loadTrial()?.startedAt == clock.now)
    }

    // MARK: Grants wait for a confirmed save

    @Test("An indeterminate activation is kept and checked, but access waits for the confirming save")
    func anIndeterminateActivationWaits() async throws {
        try endedTrial()
        client.activation = .activated(activation("inst_1"))
        let manager = makeManager()
        #expect(manager.state == .trialEnded)
        let seen = Snapshots()
        manager.setOnChange { seen.append($0) }

        failing.fail(.directorySync)
        #expect(await manager.activate(key: "KEY-PAID") == .activated)
        #expect(manager.record?.instanceID == "inst_1", "the activation is kept")
        #expect(manager.state == .trialEnded, "access stays with what the store last confirmed")
        #expect(!manager.isFeatureEnabled)
        #expect(isIndeterminate(manager.storageError))
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac")], "the activation is not released")
        #expect(try disk.loadRecord()?.instanceID == "inst_1") // in place

        // The sync keeps failing: ticks repeat the write, nothing turns on.
        for _ in 0..<3 {
            clock.advance(60)
            await manager.tick()
            #expect(manager.state == .trialEnded)
            #expect(isIndeterminate(manager.storageError))
        }
        #expect((failing.hits[.directorySync] ?? 0) >= 4, "the record is written again on every tick (the ended trial's own save fails too)")
        #expect(!seen.states(now: clock.now, uptime: clock.uptime).contains { $0.isFeatureEnabled }, "never enabled meanwhile")
        #expect(client.calls.count == 1)

        // Confirmed: licensed, clean.
        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(manager.isFeatureEnabled)
        #expect(manager.storageError == nil)
        #expect(try disk.loadRecord()?.instanceID == "inst_1")
        #expect(client.calls.count == 1)

        // A restart over the confirmed record is licensed too.
        #expect(makeManager().state == .licensed)
    }

    @Test("A replacing activation whose save is indeterminate keeps the old record's access and tombstone until durable")
    func anIndeterminateReplacementKeepsTheTombstone() async throws {
        try endedTrial()
        try paidRecord(instance: "inst_old", key: "KEY-OLD")
        client.validation = .invalid
        let manager = makeManager()
        failing.fail(.write) // the revoked record cannot be saved: the journal protects
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_old"] != nil)
        failing.fail(.write, false)

        // A new key: its save lands but is not known durable.
        client.activation = .activated(activation("inst_new"))
        client.deactivation = .deactivated
        failing.fail(.directorySync)
        #expect(await manager.activate(key: "KEY-NEW") == .activated)
        #expect(manager.record?.instanceID == "inst_new")
        #expect(manager.state == .revoked, "access stays what the last confirmed record allows")
        #expect(!manager.isFeatureEnabled)
        #expect(isIndeterminate(manager.storageError))
        #expect(journal.entries["inst_old"] != nil, "the old activation stays tombstoned while the replacement is not durable")
        #expect(client.calls.contains(.deactivate(instance: "inst_old")), "the replaced activation is released as usual")
        #expect(!client.calls.contains(.deactivate(instance: "inst_new")), "the new one is not")
        #expect(try disk.loadRecord()?.instanceID == "inst_new")

        await manager.tick()
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_old"] != nil)

        // Durable: licensed, the tombstone goes.
        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(manager.storageError == nil)
        #expect(journal.entries.isEmpty)
        #expect(try disk.loadRecord()?.instanceID == "inst_new")
    }

    @Test("valid:true whose save is indeterminate keeps Revoked and the journal entry until the confirming save")
    func anIndeterminateGrantFromRevokedWaits() async throws {
        try endedTrial()
        try paidRecord()
        client.validation = .invalid
        let manager = makeManager()
        failing.fail(.write)
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_1"] != nil)
        failing.fail(.write, false)

        client.validation = .valid(serverDate: clock.now)
        failing.fail(.directorySync)
        clock.advance(120)
        await manager.check()
        #expect(manager.record?.isRevoked == false, "Dodo's valid:true is kept in memory")
        #expect(manager.state == .revoked, "but access waits for the confirming save")
        #expect(!manager.isFeatureEnabled)
        #expect(isIndeterminate(manager.storageError))
        #expect(journal.entries["inst_1"] != nil, "the entry goes only once the grant is durable")
        #expect(try disk.loadRecord()?.isRevoked == false)

        clock.advance(60)
        await manager.tick()
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_1"] != nil)

        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(manager.storageError == nil)
        #expect(journal.entries.isEmpty)
    }

    @Test("valid:true after grace whose save is indeterminate keeps CheckRequired until the confirming save")
    func anIndeterminateGrantAfterGraceWaits() async throws {
        try endedTrial()
        try paidRecord(lastSuccessAge: 8 * LicensingTests.Clock.day)
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        #expect(manager.state == .checkRequired)

        failing.fail(.directorySync)
        await manager.check()
        #expect(manager.record?.lastSuccessAt == clock.now)
        #expect(manager.state == .checkRequired, "earned nothing new yet")
        #expect(isIndeterminate(manager.storageError))
        #expect(client.calls.count == 1)

        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(manager.storageError == nil)
        #expect(client.calls.count == 1, "the retry is a save, not another check")
    }

    @Test("valid:true settling an unreadable journal entry rebuilds the journal only once the grant is durable")
    func anIndeterminateGrantSettlesTheUnreadableJournalOnlyWhenDurable() async throws {
        try endedTrial()
        try paidRecord()
        journal.unreadable = ["inst_1"]
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        #expect(manager.state == .checkRequired, "an unreadable entry restricts")
        #expect(manager.journalUnreadable)

        failing.fail(.directorySync)
        await manager.check()
        #expect(manager.state == .checkRequired, "still restricted: the grant is not durable")
        #expect(!manager.isFeatureEnabled)
        #expect(journal.unreadable.contains("inst_1"), "the unreadable entry is left in place")
        #expect(isIndeterminate(manager.storageError))

        clock.advance(60)
        await manager.tick()
        #expect(manager.state == .checkRequired)
        #expect(journal.unreadable.contains("inst_1"))

        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(!journal.unreadable.contains("inst_1"), "rebuilt without the entry once the record is durable")
        #expect(journal.entries["inst_1"] == nil)
        #expect(!manager.journalUnreadable)
        #expect(manager.storageError == nil)
    }

    @Test("valid:false on an activation whose grant is pending revokes at once")
    func aRevocationOverridesAPendingGrant() async throws {
        try endedTrial()
        client.activation = .activated(activation("inst_1"))
        let manager = makeManager()
        failing.fail(.directorySync)
        #expect(await manager.activate(key: "KEY-PAID") == .activated)
        #expect(manager.state == .trialEnded)

        client.validation = .invalid
        clock.advance(LicensingTests.Clock.day + 60)
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(manager.record?.isRevoked == true)
        #expect(journal.entries["inst_1"] != nil)
        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.state == .revoked, "a confirmed save of a revoked record grants nothing")
        #expect(manager.storageError == nil)
    }

    // MARK: The provisional trial

    @Test("An indeterminate provisional trial grants nothing and calls no registry until a save succeeds; the same record is saved again")
    func anIndeterminateProvisionalTrialWaits() async throws {
        device.uuid = nil // the fallback id must be durable before it is ever sent
        registry.result = .registered(startedAt: clock.now, now: clock.now)
        // The records directory exists; the trial file does not.
        try disk.savePendingCleanups([PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")])
        try disk.savePendingCleanups([])

        failing.fail(.directorySync)
        let manager = makeManager()
        let seen = Snapshots()
        manager.setOnChange { seen.append($0) }
        #expect(manager.state == .trialUnavailable, "access waits for a durable save")
        #expect(!manager.isFeatureEnabled)
        #expect(manager.trial == nil)
        #expect(isIndeterminate(manager.trialStorageError))
        let written = try disk.loadTrial()
        #expect(written?.startedAt == clock.now) // in place, not known durable
        #expect(written?.fallbackDeviceID != nil)

        // The sync keeps failing across ticks, a launch check and a wake:
        // the same record is saved again each time, nothing turns on, the
        // registry is never asked.
        await manager.checkOnLaunch()
        for _ in 0..<3 {
            clock.advance(60)
            await manager.tick(wake: true)
            #expect(manager.state == .trialUnavailable)
            #expect(isIndeterminate(manager.trialStorageError))
        }
        #expect(registry.devices.isEmpty)
        #expect(failing.hits[.directorySync] == 4, "the start and one retry per tick")
        #expect(try disk.loadTrial() == written, "the very same record, saved again")
        #expect(!seen.states(now: clock.now, uptime: clock.uptime).contains { $0.isFeatureEnabled })

        // An ordinary failure in between (the directory unreadable) changes
        // nothing about the candidate either.
        #expect(chmod(sandbox.records.path, 0o000) == 0)
        clock.advance(60)
        await manager.tick()
        #expect(manager.state == .trialUnavailable)
        #expect(Fixtures.isUnavailable(manager.trialStorageError))
        #expect(chmod(sandbox.records.path, 0o700) == 0)
        clock.advance(60)
        await manager.tick()
        #expect(isIndeterminate(manager.trialStorageError))
        #expect(try disk.loadTrial() == written)

        // A save succeeds: one trial, with the original start and fallback
        // id, running and registered with that id.
        failing.fail(.directorySync, false)
        clock.advance(60)
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(manager.isFeatureEnabled)
        #expect(manager.trialStorageError == nil)
        #expect(manager.trial?.startedAt == written?.startedAt, "the same trial, not a new one")
        #expect(manager.trial?.fallbackDeviceID == written?.fallbackDeviceID)
        #expect(try disk.loadTrial()?.startedAt == written?.startedAt)
        #expect(registry.devices == [TrialDevice.hash(app: LicenseManager.trialAppID, hardwareID: written!.fallbackDeviceID!)])
    }

    // MARK: Removal

    @Test("Remove this Mac whose delete is indeterminate stays removed and retries the delete")
    func anIndeterminateRemovalRetries() async throws {
        try endedTrial()
        try paidRecord()
        client.deactivation = .deactivated
        let manager = makeManager()
        #expect(manager.state == .licensed)

        failing.fail(.directorySync)
        #expect(await manager.removeThisMac() == .storageUnavailable)
        #expect(manager.state == .trialEnded)
        #expect(isIndeterminate(manager.storageError))
        #expect(try disk.loadRecord() == nil) // gone from the directory
        #expect(journal.entries["inst_1"] != nil, "tombstoned until the deletion is durable")
        let restarted = makeManager()
        #expect(restarted.state == .trialEnded)

        failing.fail(.directorySync, false)
        await manager.tick()
        #expect(manager.storageError == nil)
        #expect(journal.entries.isEmpty)
        #expect(try disk.loadTrial() != nil, "the trial record is never deleted")
    }
}
