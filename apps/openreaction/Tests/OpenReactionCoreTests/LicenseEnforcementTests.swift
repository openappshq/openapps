import Foundation
import OpenReactionCore
import Testing

/// Enforcement never waits on storage: the manager runs on its own actor
/// and hands over its snapshot before it touches the store.
@Suite("License enforcement timing")
struct LicenseEnforcementTests {
    /// A store whose writes — and, once asked, trial-marker reads — block
    /// until the test lets them through.
    final class BlockingStore: LicenseStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _record: LicenseRecord?
        private let gate = DispatchSemaphore(value: 0)
        private(set) var blockedSaves = 0
        private(set) var trialReads = 0
        var blockTrialReads = false

        init(record: LicenseRecord?) { _record = record }

        var record: LicenseRecord? { lock.withLock { _record } }
        var isBlocked: Bool { lock.withLock { blockedSaves > 0 } }
        var trialReadCount: Int { lock.withLock { trialReads } }

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
        func loadTrialUsed() throws(LicenseStoreError) -> Bool {
            lock.withLock { trialReads += 1 }
            if lock.withLock({ blockTrialReads }) { gate.wait() }
            return false
        }
        func markTrialUsed() throws(LicenseStoreError) {}
        func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] { [] }
        func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {}
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
            licenseKey: "KEY", instanceID: "inst_1", productID: "pdt_P", kind: .paid,
            activatedAt: now.addingTimeInterval(-86_400), lastSuccessAt: now.addingTimeInterval(-60)
        )
        let store = BlockingStore(record: record)
        let journal = Journal()
        let seen = Seen()
        let manager = LicenseManager(products: LicenseProducts(paid: ["pdt_P"], trial: []), client: Client(), store: store, journal: journal)
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
            licenseKey: "KEY", instanceID: "inst_1", productID: "pdt_P", kind: .paid,
            activatedAt: now.addingTimeInterval(-86_400), lastSuccessAt: now.addingTimeInterval(-60)
        )
        let store = BlockingStore(record: record)
        let journal = Journal()
        let seen = Seen()
        let manager = LicenseManager(products: LicenseProducts(paid: ["pdt_P"], trial: []), client: Client(), store: store, journal: journal)
        await manager.setOnChange { seen.append($0) }
        await manager.load()
        let readsAfterLoad = store.trialReadCount
        #expect(seen.snapshots.last?.state(now: now) == .licensed)

        // From here every trial-marker read and every journal write hangs.
        store.blockTrialReads = true
        journal.blockWrites = true
        let check = Task { await manager.check() }
        let deadline = Date().addingTimeInterval(5)
        while !journal.isBlocked, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(journal.isBlocked) // stuck in the journal write ...
        #expect(seen.snapshots.last?.state(now: now) == .revoked) // ... with the revocation already out
        #expect(store.trialReadCount == readsAfterLoad) // building snapshots read nothing
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
        #expect(store.trialReadCount == readsAfterLoad)
    }
}
