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
        /// Once set, reading the record hangs until released (a Keychain retry that stalls).
        var blockReads = false
        /// Reading the cleanups fails, so every tick retries storage.
        var failCleanupReads = false
        private var blockedReads = 0
        var isReadBlocked: Bool { lock.withLock { blockedReads > 0 } }

        func release() { gate.signal() }

        func loadRecord() throws(LicenseStoreError) -> LicenseRecord? {
            if lock.withLock({ blockReads }) {
                lock.withLock { blockedReads += 1 }
                gate.wait()
                lock.withLock { blockedReads -= 1 }
            }
            return record
        }
        func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
            lock.withLock { blockedSaves += 1 }
            gate.wait() // the Keychain is waiting for the user, say
            lock.withLock {
                blockedSaves -= 1
                _record = record
            }
        }
        func clearRecord() throws(LicenseStoreError) { lock.withLock { _record = nil } }
        func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] {
            if lock.withLock({ failCleanupReads }) { throw .unavailable("locked") }
            return []
        }
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

    /// A registry that is never reachable.
    struct OfflineRegistry: TrialRegistryClient {
        func register(device: String) async -> TrialRegistrationResult { .unreachable }
    }

    /// Holds a clock-behind snapshot while a storage retry blocks the manager,
    /// corrects the wall clock to 30 min inside the tolerance and lets time pass:
    /// nothing unlocks until the manager observes, and then exactly the 15 min
    /// that were left remain, counted on the monotonic clock.
    private static func heldBehindSnapshotStaysLocked(registered: Bool, elapsed: TimeInterval, lockedFor: TimeInterval, endsAs ended: LicenseState) async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let start = clock.now
        let minute: TimeInterval = 60
        let store = BlockingStore(record: nil)
        store.failCleanupReads = true // a Keychain retry runs on every tick
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: start.addingTimeInterval(-elapsed), lastSeenAt: start, registered: registered
        ))
        let seen = Seen()
        let manager = Self.manager(store: store, journal: Journal(), trialStore: trialStore, registry: OfflineRegistry(), clock: clock)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        // Wake with the clock 5 days behind: published and held behind.
        clock.setWall(start.addingTimeInterval(-5 * 86_400))
        await manager.wake()
        let held = seen.snapshots.last
        #expect(held?.state(now: clock.now, uptime: clock.uptime) == .trialClockBehind)
        // The next storage retry blocks the manager.
        store.blockReads = true
        let stuck = Task { await manager.tick() }
        await Self.eventually { store.isReadBlocked }
        #expect(store.isReadBlocked)
        // The user corrects the clock to 30 min inside the tolerance; time passes.
        clock.setWall(start.addingTimeInterval(-30 * minute))
        clock.advanceMono(lockedFor)
        for snapshot in [held, seen.snapshots.last] {
            #expect(snapshot?.state(now: clock.now, uptime: clock.uptime) == .trialClockBehind)
            #expect(snapshot?.state(now: clock.now, uptime: clock.uptime, wakeSince: clock.uptime) == .trialClockBehind)
            #expect(snapshot?.deadlineDelay(now: clock.now, uptime: clock.uptime) == LicensePolicy.minimumRetryDelay)
        }
        // (The manager itself cannot be asked meanwhile: its actor is stuck in the read.)
        // Storage returns; the manager observes the corrected clock and unlocks.
        store.blockReads = false
        store.release()
        await stuck.value
        #expect(await manager.trialClockBehind == false)
        #expect(await manager.isFeatureEnabled)
        #expect(await manager.nextDeadlineDelay == 15 * minute) // the time locked was never charged
        let released = seen.snapshots.last
        #expect(released?.state(now: clock.now, uptime: clock.uptime).isFeatureEnabled == true)
        clock.advanceMono(15 * minute) // wall clock stays put: monotonic time still ends it
        #expect(released?.state(now: clock.now, uptime: clock.uptime) == ended)
        #expect(await manager.state == ended)
        // Released once, counted once: a later wake agrees.
        await manager.wake()
        #expect(await manager.state == ended)
        #expect(abs((await manager.trialElapsed ?? 0) - (elapsed + 15 * minute)) < 0.001)
    }

    @Test("Review 3: a held clock-behind snapshot never unlocks while the manager is blocked; a registered trial at 71 h 45 m then ends after 15 min")
    func heldBehindRegisteredTrial() async {
        await Self.heldBehindSnapshotStaysLocked(registered: true, elapsed: 71 * 3600 + 45 * 60, lockedFor: 20 * 60, endsAs: .trialEnded)
    }

    @Test("Review 3: a held clock-behind snapshot never unlocks while the manager is blocked; an unregistered trial at 23 h 45 m then stops after 15 min")
    func heldBehindUnregisteredTrial() async {
        await Self.heldBehindSnapshotStaysLocked(registered: false, elapsed: 23 * 3600 + 45 * 60, lockedFor: 20 * 60, endsAs: .trialNeedsConnection)
    }

    @Test("Review 3: with the wall clock fixed inside the tolerance, a blocked manager keeps the Mac locked for as long as it stays blocked")
    func heldBehindStaysLockedForAnyStall() async {
        await Self.heldBehindSnapshotStaysLocked(registered: true, elapsed: 71 * 3600 + 45 * 60, lockedFor: 10 * 3600, endsAs: .trialEnded)
    }

    /// A registry that answers at once with a fixed start.
    struct AnsweringRegistry: TrialRegistryClient {
        let startedAt: Date
        let now: Date
        func register(device: String) async -> TrialRegistrationResult { .registered(startedAt: startedAt, now: now) }
    }

    struct Device: DeviceIdentity {
        func hardwareUUID() -> String? { "00000000-1111-2222-3333-444444444444" }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        private var _uptime: TimeInterval = 1_000
        init(_ now: Date) { _now = now }
        var now: Date { lock.withLock { _now } }
        var uptime: TimeInterval { lock.withLock { _uptime } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock {
                _now = _now.addingTimeInterval(seconds)
                _uptime += max(0, seconds)
            }
        }
        /// Moves only the wall clock.
        func setWall(_ date: Date) { lock.withLock { _now = date } }
        /// Moves only the monotonic clock.
        func advanceMono(_ seconds: TimeInterval) { lock.withLock { _uptime += seconds } }
    }

    private static func manager(
        store: any LicenseStore, journal: any InvalidationJournal, trialStore: any TrialStore,
        registry: any TrialRegistryClient = Registry(), clock: Clock? = nil
    ) -> LicenseManager {
        LicenseManager(
            products: LicenseProducts(paid: ["pdt_P"]), client: Client(), store: store, journal: journal,
            trialStore: trialStore, registry: registry, device: Device(), now: { clock?.now ?? Date() },
            uptime: { clock?.uptime ?? LicenseManager.continuousUptime() }
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
        #expect(seen.snapshots.last?.state(now: now, uptime: 0) == .licensed)

        // Dodo says valid:false; the Keychain write then hangs.
        let check = Task { await manager.check() }
        let deadline = Date().addingTimeInterval(5)
        while !store.isBlocked, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(store.isBlocked)
        // The revocation was already handed over — and journaled — while the save is stuck.
        #expect(seen.snapshots.last?.state(now: now, uptime: 0) == .revoked)
        #expect(try journal.entry(instanceID: "inst_1") == JournalEntry(seq: 2))
        #expect(store.record?.isRevoked == false) // not yet saved
        // The main actor is not the one waiting.
        let mainFree = await MainActor.run { true }
        #expect(mainFree)
        // A deadline decided from the snapshot needs no storage either.
        #expect(seen.snapshots.last?.state(now: now.addingTimeInterval(30 * 86_400), uptime: 0) == .revoked)

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
        #expect(seen.snapshots.last?.state(now: now, uptime: 0) == .licensed)

        // From here every trial-record read or save and every journal write hangs.
        trialStore.blockIO = true
        journal.blockWrites = true
        let check = Task { await manager.check() }
        let deadline = Date().addingTimeInterval(5)
        while !journal.isBlocked, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(journal.isBlocked) // stuck in the journal write ...
        #expect(seen.snapshots.last?.state(now: now, uptime: 0) == .revoked) // ... with the revocation already out
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
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trial(daysLeft: 1))
        #expect(seen.snapshots.last?.deadlineDelay(now: clock.now, uptime: clock.uptime) == 60)

        // The app keeps running for 2 minutes; every trial save now hangs.
        trialStore.blockIO = true
        clock.advance(120)
        // The deadline comes from memory: the published snapshot alone says it ended.
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialEnded)
        let tick = Task { await manager.tick() }
        await Self.eventually { trialStore.isBlocked }
        #expect(trialStore.isBlocked) // the end-of-trial save is stuck ...
        #expect(seen.snapshots.last?.trial?.lastSeenAt == clock.now) // ... after the new time was published
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialEnded)
        #expect(await MainActor.run { true })
        trialStore.release()
        await tick.value
        #expect(trialStore.record?.lastSeenAt == clock.now)
        #expect(await manager.state == .trialEnded)
    }

    @Test("Review 2, P0-1: monotonic time ends the provisional limit while a registration save hangs and the wall clock goes back")
    func provisionalLimitProjectsThroughAHungSave() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let hour: TimeInterval = 3600
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-23 * hour), lastSeenAt: clock.now, registered: false
        ))
        let seen = Seen()
        let manager = Self.manager(
            store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore,
            registry: AnsweringRegistry(startedAt: clock.now, now: clock.now), clock: clock
        )
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        trialStore.blockIO = true // the registration's save hangs
        let launch = Task { await manager.checkOnLaunch() }
        await Self.eventually { trialStore.isBlocked }
        #expect(trialStore.isBlocked)
        let published = seen.snapshots.last
        #expect(published?.deadlineDelay(now: clock.now, uptime: clock.uptime) == hour)
        clock.setWall(clock.now.addingTimeInterval(-2 * hour)) // the wall clock goes back ...
        clock.advanceMono(2 * hour) // ... while two hours really pass
        #expect(published?.state(now: clock.now, uptime: clock.uptime) == .trialNeedsConnection)
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialNeedsConnection)
        trialStore.blockIO = false
        trialStore.release()
        await launch.value
        #expect(seen.snapshots.last?.trial?.registered == true)
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trial(daysLeft: 2))
    }

    @Test("Review 2, P0-1: a registered trial ends at 72 h of monotonic time while a save hangs and the wall clock goes back")
    func registeredTrialProjectsThroughAHungSave() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let hour: TimeInterval = 3600
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-71 * hour), lastSeenAt: clock.now, registered: true
        ))
        let seen = Seen()
        let manager = Self.manager(store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore, clock: clock)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        clock.advance(60)
        trialStore.blockIO = true
        let quit = Task { await manager.saveTrialBeforeQuit() } // a save that hangs
        await Self.eventually { trialStore.isBlocked }
        #expect(trialStore.isBlocked)
        let published = seen.snapshots.last
        #expect(published?.deadlineDelay(now: clock.now, uptime: clock.uptime) == hour - 60)
        clock.setWall(clock.now.addingTimeInterval(-2 * hour))
        clock.advanceMono(2 * hour)
        #expect(published?.state(now: clock.now, uptime: clock.uptime) == .trialEnded)
        trialStore.blockIO = false
        trialStore.release()
        await quit.value
        #expect(await manager.state == .trialEnded)
    }

    @Test("Review 2, P0-1: a wake restricts before any I/O while a registry request hangs")
    func wakeRestrictsBeforeQueuedIO() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let hour: TimeInterval = 3600
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-hour), lastSeenAt: clock.now, registered: false
        ))
        let registry = Registry()
        let seen = Seen()
        let manager = Self.manager(store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore, registry: registry, clock: clock)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        let launch = Task { await manager.checkOnLaunch() }
        await Self.eventually { registry.callCount == 1 }
        #expect(registry.callCount == 1) // the manager's queue is stuck on the network
        clock.setWall(clock.now.addingTimeInterval(-5 * 86_400)) // set back while asleep
        clock.advanceMono(hour)
        let published = seen.snapshots.last
        #expect(published?.state(now: clock.now, uptime: clock.uptime) == .trial(daysLeft: 3)) // no wake: still counting
        // The app layer projects the wake from the snapshot it holds, with no manager work at all.
        #expect(published?.state(now: clock.now, uptime: clock.uptime, wakeSince: clock.uptime) == .trialClockBehind)
        // The manager publishes the restriction before its queued work.
        let woke = Task { await manager.wake() }
        await Self.eventually { seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialClockBehind }
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialClockBehind)
        #expect(registry.callCount == 1)
        registry.release()
        await launch.value
        await woke.value
        #expect(await manager.state == .trialClockBehind)
        #expect(trialStore.record?.registered == false)
    }

    @Test("A hung save, a tick waiting behind it and a wake meanwhile count the time once and never report a clock behind")
    func waitingObservationsNeverRewindTheClock() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-day), lastSeenAt: clock.now, registered: true
        ))
        let seen = Seen()
        let manager = Self.manager(store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore, clock: clock)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        clock.advance(hour) // the hourly save is due
        trialStore.blockIO = true
        let blocked = Task { await manager.tick() } // its save hangs on the license actor
        await Self.eventually { trialStore.isBlocked }
        #expect(trialStore.isBlocked)
        let waiting = Task { await manager.tick() } // a tick waiting behind it
        clock.advance(2 * hour) // the Mac sleeps two hours
        let woke = Task { await manager.wake() }
        trialStore.blockIO = false
        trialStore.release()
        await blocked.value
        await waiting.value
        await woke.value
        #expect(!seen.snapshots.contains { $0.state(now: clock.now, uptime: clock.uptime) == .trialClockBehind })
        #expect(await manager.trialClockBehind == false)
        #expect(abs((await manager.trialElapsed ?? 0) - (day + 3 * hour)) < 0.001) // counted once
        await manager.wake()
        #expect(await manager.trialClockBehind == false)
        #expect(await manager.state == .trial(daysLeft: 2))
        await manager.saveTrialBeforeQuit()
        let relaunched = Self.manager(store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore, clock: clock)
        await relaunched.load()
        #expect(await relaunched.trialClockBehind == false)
        #expect(await relaunched.state == .trial(daysLeft: 2))
        #expect(abs((await relaunched.trialElapsed ?? 0) - (day + 3 * hour)) < 0.001)
    }

    @Test("29. A registration that extends the trial is not published while its save hangs past 24 h")
    func anExtensionWaitsForItsSave() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let hour: TimeInterval = 3600
        let trialStore = BlockingTrialStore(record: TrialRecord(
            startedAt: clock.now.addingTimeInterval(-23 * hour), lastSeenAt: clock.now, registered: false
        ))
        let seen = Seen()
        let manager = Self.manager(
            store: BlockingStore(record: nil), journal: Journal(), trialStore: trialStore,
            registry: AnsweringRegistry(startedAt: clock.now, now: clock.now), clock: clock
        )
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trial(daysLeft: 3))

        trialStore.blockIO = true // the registration's save hangs
        let launch = Task { await manager.checkOnLaunch() }
        await Self.eventually { trialStore.isBlocked }
        #expect(trialStore.isBlocked)
        #expect(!seen.snapshots.contains { $0.trial?.registered == true })
        clock.advance(2 * hour) // 25 h, save still stuck
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialNeedsConnection)
        trialStore.blockIO = false
        trialStore.release()
        await launch.value
        #expect(trialStore.record?.registered == true)
        #expect(seen.snapshots.last?.trial?.registered == true)
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trial(daysLeft: 2)) // on again once saved
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
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trial(daysLeft: 3))
        let launch = Task { await manager.checkOnLaunch() }
        await Self.eventually { registry.callCount == 1 }
        #expect(registry.callCount == 1) // the registry is not answering
        clock.advance(120)
        #expect(seen.snapshots.last?.state(now: clock.now, uptime: clock.uptime) == .trialNeedsConnection)
        registry.release()
        await launch.value
        #expect(await manager.state == .trialNeedsConnection)
    }
}
