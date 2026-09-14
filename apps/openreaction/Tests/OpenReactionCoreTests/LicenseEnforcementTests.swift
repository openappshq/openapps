import Foundation
import OpenReactionCore
import Testing

/// Enforcement never waits on storage: the manager runs on its own actor
/// and hands over its snapshot before it touches the store.
@Suite("License enforcement timing")
struct LicenseEnforcementTests {
    /// A store whose writes block until the test lets them through.
    final class BlockingStore: LicenseStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _record: LicenseRecord?
        private let gate = DispatchSemaphore(value: 0)
        private(set) var blockedSaves = 0

        init(record: LicenseRecord?) { _record = record }

        var record: LicenseRecord? { lock.withLock { _record } }
        var isBlocked: Bool { lock.withLock { blockedSaves > 0 } }

        func release() { gate.signal() }

        func loadRecord() throws(LicenseStoreError) -> LicenseRecord? { record }
        func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
            lock.withLock { blockedSaves += 1 }
            gate.wait() // the Keychain is waiting for the user, say
            lock.withLock {
                blockedSaves -= 1
                _record = record
            }
        }
        func clearRecord() throws(LicenseStoreError) { lock.withLock { _record = nil } }
        func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] { [] }
        func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {}
    }

    /// The trial record; once asked, reads and saves block until released.
    final class BlockingTrialStore: TrialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _record: TrialRecord?
        private let gate = DispatchSemaphore(value: 0)
        private var blocked = 0
        private var reads = 0
        var blockIO = false

        init(record: TrialRecord?) { _record = record }

        var record: TrialRecord? { lock.withLock { _record } }
        var isBlocked: Bool { lock.withLock { blocked > 0 } }
        var readCount: Int { lock.withLock { reads } }
        func release() { gate.signal() }

        private func waitIfBlocking() {
            guard lock.withLock({ blockIO }) else { return }
            lock.withLock { blocked += 1 }
            gate.wait()
            lock.withLock { blocked -= 1 }
        }

        func loadTrial() throws(LicenseStoreError) -> TrialRecord? {
            lock.withLock { reads += 1 }
            waitIfBlocking()
            return record
        }
        func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError) {
            waitIfBlocking()
            lock.withLock { _record = trial }
        }
    }

    /// A registry that, once asked, holds its answer until released.
    final class Registry: TrialRegistryClient, @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }
        func release() { gate.signal() }
        func register(device: String) async -> TrialRegistrationResult {
            lock.withLock { calls += 1 }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.gate.wait()
                    continuation.resume()
                }
            }
            return .unreachable
        }
    }

    struct Device: DeviceIdentity {
        func hardwareUUID() -> String? { "00000000-1111-2222-3333-444444444444" }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ now: Date) { _now = now }
        var now: Date { lock.withLock { _now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
    }

    private static func manager(
        store: any LicenseStore, journal: any InvalidationJournal, trialStore: any TrialStore,
        registry: any TrialRegistryClient = Registry(), clock: Clock? = nil
    ) -> LicenseManager {
        LicenseManager(
            products: LicenseProducts(paid: ["pdt_P"]), client: Client(), store: store, journal: journal,
            trialStore: trialStore, registry: registry, device: Device(), now: { clock?.now ?? Date() }
        )
    }

    /// Waits (briefly, in real time) for a condition another thread settles.
    private static func eventually(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// A journal whose writes block, once asked, until released.
    final class Journal: InvalidationJournal, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: JournalEntry] = [:]
        private let gate = DispatchSemaphore(value: 0)
        private var blockedWrites = 0
        var blockWrites = false
        var isBlocked: Bool { lock.withLock { blockedWrites > 0 } }
        func release() { gate.signal() }
        func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? { lock.withLock { entries[instanceID] } }
        func record(instanceID: String, entry: JournalEntry) -> Bool {
            if lock.withLock({ blockWrites }) {
                lock.withLock { blockedWrites += 1 }
                gate.wait() // preferences are stuck, say
                lock.withLock { blockedWrites -= 1 }
            }
            lock.withLock { entries[instanceID] = entry }
            return true
        }
        func clear(instanceID: String, upTo seq: UInt64) -> Bool {
            lock.withLock { entries[instanceID] = nil }
            return true
        }
        func replaceUnreadable(instanceID: String, with entry: JournalEntry?) -> Bool { true }
    }

    final class Client: LicenseClient, @unchecked Sendable {
        func activate(licenseKey: String, name: String) async -> ActivationResult { .unreachable }
        func validate(licenseKey: String, instanceID: String) async -> ValidationResult { .invalid }
        func deactivate(licenseKey: String, instanceID: String) async -> DeactivationResult { .deactivated }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshots: [LicenseSnapshot] = []
        var snapshots: [LicenseSnapshot] { lock.withLock { _snapshots } }
        func append(_ snapshot: LicenseSnapshot) { lock.withLock { _snapshots.append(snapshot) } }
    }

    @Test func aRevocationIsPublishedBeforeTheKeychainAnswers() async throws {
        let now = Date()
        let record = LicenseRecord(
            licenseKey: "KEY", instanceID: "inst_1", productID: "pdt_P",
            activatedAt: now.addingTimeInterval(-86_400), lastSuccessAt: now.addingTimeInterval(-60)
        )
        let store = BlockingStore(record: record)
        let journal = Journal()
        let seen = Seen()
        let manager = Self.manager(store: store, journal: journal, trialStore: BlockingTrialStore(record: nil))
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        #expect(seen.snapshots.last?.state(now: now) == .licensed)

        // Dodo says valid:false; the Keychain write then hangs.
        let check = Task { await manager.check() }
        let deadline = Date().addingTimeInterval(5)
        while !store.isBlocked, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(store.isBlocked)
        // The revocation was already handed over — and journaled — while the save is stuck.
        #expect(seen.snapshots.last?.state(now: now) == .revoked)
        #expect(try journal.entry(instanceID: "inst_1") == JournalEntry(seq: 2))
        #expect(store.record?.isRevoked == false) // not yet saved
        // The main actor is not the one waiting.
        let mainFree = await MainActor.run { true }
        #expect(mainFree)
        // A deadline decided from the snapshot needs no storage either.
        #expect(seen.snapshots.last?.state(now: now.addingTimeInterval(30 * 86_400)) == .revoked)

        store.release()
        await check.value
        #expect(store.record?.isRevoked == true)
        #expect(await manager.state == .revoked)
    }

    @Test func aRevocationIsPublishedBeforeTheJournalOrAnyKeychainRead() async throws {
        let now = Date()
        let record = LicenseRecord(
            licenseKey: "KEY", instanceID: "inst_1", productID: "pdt_P",
            activatedAt: now.addingTimeInterval(-86_400), lastSuccessAt: now.addingTimeInterval(-60)
        )
        let store = BlockingStore(record: record)
        let journal = Journal()
        let seen = Seen()
        let trialStore = BlockingTrialStore(record: nil)
        let manager = Self.manager(store: store, journal: journal, trialStore: trialStore)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        let readsAfterLoad = trialStore.readCount
        #expect(seen.snapshots.last?.state(now: now) == .licensed)

        // From here every trial-record read or save and every journal write hangs.
        trialStore.blockIO = true
        journal.blockWrites = true
        let check = Task { await manager.check() }
        let deadline = Date().addingTimeInterval(5)
        while !journal.isBlocked, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(journal.isBlocked) // stuck in the journal write ...
        #expect(seen.snapshots.last?.state(now: now) == .revoked) // ... with the revocation already out
        #expect(trialStore.readCount == readsAfterLoad) // building snapshots read nothing
        #expect(try journal.entry(instanceID: "inst_1") == nil)
        #expect(store.record?.isRevoked == false)
        #expect(!store.isBlocked) // the Keychain was not even asked yet

        journal.release() // the journal accepts: now the Keychain hangs
        while !store.isBlocked, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(store.isBlocked)
        #expect(try journal.entry(instanceID: "inst_1") == JournalEntry(seq: 2)) // journal before Keychain
        #expect(store.record?.isRevoked == false)
        store.release()
        await check.value
        #expect(store.record?.isRevoked == true)
        #expect(trialStore.readCount == readsAfterLoad)
    }

    @Test("15. A trial ends on time while its save and the registry both hang")
    func aTrialEndsOnTimeWithoutWaitingOnIO() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let day: TimeInterval = 86_400
        // 2 days 23 h 59 min used, observed until now.
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-(3 * day - 60)), lastSeenAt: clock.now, registered: true
        ))
        let seen = Seen()
        let manager = Self.manager(store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore, clock: clock)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        #expect(seen.snapshots.last?.state(now: clock.now) == .trial(daysLeft: 1))
        #expect(seen.snapshots.last?.nextDeadline == clock.now.addingTimeInterval(60))

        // The app keeps running for 2 minutes; every trial save now hangs.
        trialStore.blockIO = true
        clock.advance(120)
        // The deadline comes from memory: the published snapshot alone says it ended.
        #expect(seen.snapshots.last?.state(now: clock.now) == .trialEnded)
        let tick = Task { await manager.tick() }
        await Self.eventually { trialStore.isBlocked }
        #expect(trialStore.isBlocked) // the end-of-trial save is stuck ...
        #expect(seen.snapshots.last?.trial?.lastSeenAt == clock.now) // ... after the new time was published
        #expect(seen.snapshots.last?.state(now: clock.now) == .trialEnded)
        #expect(await MainActor.run { true })
        trialStore.release()
        await tick.value
        #expect(trialStore.record?.lastSeenAt == clock.now)
        #expect(await manager.state == .trialEnded)
    }

    @Test("20. An unregistered trial stops at its offline limit while the registry call hangs")
    func theOfflineLimitDoesNotWaitOnTheRegistry() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let day: TimeInterval = 86_400
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-(day - 60)), lastSeenAt: clock.now, registered: false
        ))
        let registry = Registry()
        let seen = Seen()
        let manager = Self.manager(store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore, registry: registry, clock: clock)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        #expect(seen.snapshots.last?.state(now: clock.now) == .trial(daysLeft: 3))
        let launch = Task { await manager.checkOnLaunch() }
        await Self.eventually { registry.callCount == 1 }
        #expect(registry.callCount == 1) // the registry is not answering
        clock.advance(120)
        #expect(seen.snapshots.last?.state(now: clock.now) == .trialNeedsConnection)
        registry.release()
        await launch.value
        #expect(await manager.state == .trialNeedsConnection)
    }
}
