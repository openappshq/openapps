#if OPENAPPS_LICENSING
import CryptoKit
import Foundation
import OpenReactionCore

/// The invalidation journal as plain preferences: nothing secret is in it.
/// Each entry is `revoked.<SHA-256 of the instance id>` → `{seq}`, the
/// record's event sequence at the revocation or removal; entries from
/// before the sequence existed hold a time and read as `.legacy`. It exists
/// so a revocation the Keychain refused to store still holds after a
/// restart; the manager clears it once the record has durably caught up.
/// An entry that is neither form is corrupt: reported, never overwritten.
struct DefaultsInvalidationJournal: InvalidationJournal, @unchecked Sendable {
    static let suiteName = "space.openapps.openreaction.license"
    /// UserDefaults is thread-safe; the manager only ever calls from the main actor.
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: DefaultsInvalidationJournal.suiteName)) {
        self.defaults = defaults ?? .standard
    }

    func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? {
        guard let value = defaults.object(forKey: Self.key(instanceID)) else { return nil }
        if let dictionary = value as? [String: Any] { return try Self.decode(dictionary) }
        if value is NSNumber { return .legacy } // a revocation time from before the sequence existed
        throw .corrupt
    }

    private static func decode(_ dictionary: [String: Any]) throws(LicenseStoreError) -> JournalEntry {
        guard let number = dictionary["seq"] as? NSNumber, number.int64Value >= 0 else { throw .corrupt }
        return JournalEntry(seq: number.uint64Value)
    }

    func record(instanceID: String, entry new: JournalEntry) -> Bool {
        let key = Self.key(instanceID)
        // A newer revocation is never downgraded by an older one; a
        // time-based entry is always rewritten in the current form.
        if defaults.object(forKey: key) as? [String: Any] != nil,
           let existing = try? entry(instanceID: instanceID), existing.seq >= new.seq { return true }
        defaults.set(["seq": NSNumber(value: new.seq)], forKey: key)
        // Flushed before the Keychain is even tried, and read back: only a
        // value that is on disk counts as protection.
        guard defaults.synchronize(), let stored = defaults.object(forKey: key) as? [String: Any] else { return false }
        return (stored["seq"] as? NSNumber)?.uint64Value == new.seq
    }

    func clear(instanceID: String, upTo seq: UInt64) -> Bool {
        let key = Self.key(instanceID)
        // A newer entry survives an older clear; an unreadable one goes.
        if let existing = try? entry(instanceID: instanceID), existing.seq > seq { return true }
        defaults.removeObject(forKey: key)
        return defaults.synchronize() && defaults.object(forKey: key) == nil
    }

    private static func key(_ instanceID: String) -> String {
        let digest = SHA256.hash(data: Data(instanceID.utf8))
        return "revoked." + digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
