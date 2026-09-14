#if OPENAPPS_LICENSING
import Foundation
import OpenReactionCore
import Testing
@testable import OpenReaction

/// The real preferences journal against a throwaway suite.
@Suite("Defaults invalidation journal", .serialized)
struct DefaultsInvalidationJournalTests {
    static let suite = "space.openapps.openreaction.license.tests"

    struct Fixture {
        let defaults = UserDefaults(suiteName: DefaultsInvalidationJournalTests.suite)!
        let journal: DefaultsInvalidationJournal

        init() {
            defaults.removePersistentDomain(forName: DefaultsInvalidationJournalTests.suite)
            journal = DefaultsInvalidationJournal(defaults: defaults)
        }

        /// The stored key for an instance: what the journal writes for it.
        /// Leaves a `seq: 999` entry behind; callers overwrite or clear it.
        func key(for instanceID: String) -> String {
            _ = journal.record(instanceID: instanceID, entry: JournalEntry(seq: 999))
            return defaults.dictionaryRepresentation().first {
                $0.key.hasPrefix("revoked.") && ($0.value as? [String: Int]) == ["seq": 999]
            }!.key
        }
    }

    @Test func recordsAndClearsSequences() throws {
        let fixture = Fixture()
        #expect(try fixture.journal.entry(instanceID: "inst_1") == nil)
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 7)))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 7))
        #expect(try fixture.journal.entry(instanceID: "inst_2") == nil)
        #expect(fixture.journal.clear(instanceID: "inst_1", upTo: 6)) // older clear: the entry survives
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 7))
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 5))) // older record: never downgraded
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 7))
        #expect(fixture.journal.clear(instanceID: "inst_1", upTo: 7))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == nil)
        // The key is a hash: the instance id is not in the store.
        let key = fixture.key(for: "inst_1")
        #expect(!key.contains("inst_1"))
        #expect(key.count == "revoked.".count + 64)
    }

    @Test func aTimeFromBeforeTheSequenceReadsAsLegacy() throws {
        let fixture = Fixture()
        let key = fixture.key(for: "inst_1")
        fixture.defaults.set(1_800_000_000.0, forKey: key)
        #expect(try fixture.journal.entry(instanceID: "inst_1") == .legacy)
        // Rewritten by the manager in the current form on first use.
        #expect(fixture.journal.record(instanceID: "inst_1", entry: .legacy))
        #expect(fixture.defaults.object(forKey: key) as? [String: Int] == ["seq": 1])
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 1))
    }

    @Test func anUnreadableEntryIsAnErrorAndIsLeftAlone() throws {
        let fixture = Fixture()
        let key = fixture.key(for: "inst_1")
        fixture.defaults.set("garbage", forKey: key)
        #expect(throws: LicenseStoreError.corrupt) { try fixture.journal.entry(instanceID: "inst_1") }
        fixture.defaults.set(["seq": -3], forKey: key)
        #expect(throws: LicenseStoreError.corrupt) { try fixture.journal.entry(instanceID: "inst_1") }
        #expect(fixture.defaults.object(forKey: key) != nil) // reading never rewrote it
        // Only an authoritative clear removes it.
        #expect(fixture.journal.clear(instanceID: "inst_1", upTo: .max))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == nil)
    }
}
#endif
