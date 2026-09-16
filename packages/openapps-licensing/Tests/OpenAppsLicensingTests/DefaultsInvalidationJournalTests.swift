import Foundation
import OpenAppsLicensing
import OpenAppsLicensingClients
import Testing

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

        /// The hash the journal files an instance under (found through a
        /// write that is undone again).
        func hash(for instanceID: String) -> String {
            _ = journal.record(instanceID: instanceID, entry: JournalEntry(seq: 999))
            let key = versionKeys().first { (defaults.object(forKey: $0) as? [String: Int]) == ["seq": 999] }!
            _ = journal.clear(instanceID: instanceID, upTo: 999)
            return String(key.dropFirst("journal.".count).prefix(64))
        }

        func versionKeys() -> [String] {
            defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("journal.") }.sorted()
        }

        func versions(_ hash: String) -> [Int] {
            versionKeys().compactMap { key in
                key.hasPrefix("journal.\(hash).") ? Int(key.dropFirst("journal.\(hash).".count)) : nil
            }.sorted()
        }
    }

    @Test func recordsClearsAndNeverDowngrades() throws {
        let fixture = Fixture()
        let hash = fixture.hash(for: "inst_1")
        #expect(!hash.contains("inst_1") && hash.count == 64)
        #expect(try fixture.journal.entry(instanceID: "inst_1") == nil)
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 7)))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 7))
        #expect(try fixture.journal.entry(instanceID: "inst_2") == nil)
        #expect(fixture.journal.clear(instanceID: "inst_1", upTo: 6)) // older clear: the entry survives
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 7))
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 5))) // older record: never downgraded
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 7))
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 8)))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 8))
        #expect(fixture.versions(hash).count == 1) // older versions retired after the new one was read back
        #expect(fixture.journal.clear(instanceID: "inst_1", upTo: 8))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == nil)
        #expect(fixture.versions(hash).isEmpty)
    }

    @Test func aRevocationTimeFromBeforeVersionsReadsAsLegacyAndIsRewritten() throws {
        let fixture = Fixture()
        let hash = fixture.hash(for: "inst_1")
        fixture.defaults.set(1_800_000_000.0, forKey: "revoked.\(hash)")
        #expect(try fixture.journal.entry(instanceID: "inst_1") == .legacy)
        // Rewritten by the manager in the current form on first use: a new
        // version, then the old key retired.
        #expect(fixture.journal.record(instanceID: "inst_1", entry: .legacy))
        #expect(fixture.defaults.object(forKey: "revoked.\(hash)") == nil)
        #expect(fixture.versions(hash) == [1])
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 1))
    }

    @Test func anUnreadableEntryIsAnErrorThatNoReadOrClearTouches() throws {
        let fixture = Fixture()
        let hash = fixture.hash(for: "inst_1")
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 2)))
        let corruptKey = "journal.\(hash).2"
        fixture.defaults.set("garbage", forKey: corruptKey) // a newer, unreadable version
        #expect(throws: LicenseStoreError.corrupt) { try fixture.journal.entry(instanceID: "inst_1") }
        #expect(!fixture.journal.clear(instanceID: "inst_1", upTo: 99)) // a clear never removes it
        #expect(fixture.defaults.object(forKey: corruptKey) as? String == "garbage")
        fixture.defaults.set(["seq": -3], forKey: corruptKey)
        #expect(throws: LicenseStoreError.corrupt) { try fixture.journal.entry(instanceID: "inst_1") }
        fixture.defaults.set(["seq": 4, "extra": 1], forKey: corruptKey)
        #expect(throws: LicenseStoreError.corrupt) { try fixture.journal.entry(instanceID: "inst_1") }
    }

    @Test func replacingAnUnreadableEntryIsAtomic() throws {
        let fixture = Fixture()
        let hash = fixture.hash(for: "inst_1")
        fixture.defaults.set("garbage", forKey: "journal.\(hash).1")
        // With a readable entry nothing happens.
        #expect(fixture.journal.replaceUnreadable(instanceID: "inst_2", with: nil))
        // Dodo said valid: a "none" version is written and read back before
        // the unreadable one is retired.
        #expect(fixture.journal.replaceUnreadable(instanceID: "inst_1", with: nil))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == nil)
        #expect(fixture.versions(hash) == [2])
        #expect(fixture.defaults.object(forKey: "journal.\(hash).1") == nil)
        // Dodo said invalid: the revocation replaces the unreadable version.
        fixture.defaults.set("garbage", forKey: "journal.\(hash).3")
        #expect(fixture.journal.replaceUnreadable(instanceID: "inst_1", with: JournalEntry(seq: 5)))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 5))
        #expect(fixture.versions(hash) == [4])
        // A record also replaces unreadable data the same way.
        fixture.defaults.set("garbage", forKey: "journal.\(hash).5")
        #expect(fixture.journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 6)))
        #expect(try fixture.journal.entry(instanceID: "inst_1") == JournalEntry(seq: 6))
        #expect(fixture.versions(hash) == [6])
    }
}
