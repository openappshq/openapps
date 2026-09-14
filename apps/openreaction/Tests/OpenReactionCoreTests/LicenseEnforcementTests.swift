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
        func loadTrialUsed() throws(LicenseStoreError) -> Bool { false }
        func markTrialUsed() throws(LicenseStoreError) {}
        func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] { [] }
        func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {}
    }

    final class Journal: InvalidationJournal, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: JournalEntry] = [:]
        func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? { lock.withLock { entries[instanceID] } }
        func record(instanceID: String, entry: JournalEntry) -> Bool {
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
}
