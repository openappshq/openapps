#if OPENAPPS_LICENSING
import CryptoKit
import Foundation
import OpenReactionCore

/// The invalidation journal as plain preferences: nothing secret is in it.
///
/// Each activation's entry lives under versioned keys `journal.<SHA-256 of
/// the instance id>.<n>`; the newest version is the entry. A write puts the
/// new version under `n + 1`, flushes, reads it back, and only then retires
/// the older versions — so a failure at any step leaves what was there, and
/// data that cannot be read keeps protecting until an authoritative answer
/// replaces it the same way. Entries written before versions existed live
/// under `revoked.<hash>` (a revocation time, read as `.legacy`) and count
/// as version 0. A version that is neither `{seq}` nor `{none}` is corrupt:
/// reported, never overwritten by a read or a clear.
struct DefaultsInvalidationJournal: InvalidationJournal, @unchecked Sendable {
    static let suiteName = "space.openapps.openreaction.license"
    /// UserDefaults is thread-safe; the manager only ever calls from the main actor.
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: DefaultsInvalidationJournal.suiteName)) {
        self.defaults = defaults ?? .standard
    }

    // MARK: Protocol

    func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? {
        guard let newest = newestVersion(instanceID) else { return nil }
        return try Self.parse(newest.value)
    }

    func record(instanceID: String, entry new: JournalEntry) -> Bool {
        if let newest = newestVersion(instanceID), newest.number > 0,
           case .readable(let existing?) = Self.read(newest.value), existing.seq >= new.seq {
            return true // a newer (versioned) revocation is never downgraded
        }
        return install(["seq": NSNumber(value: new.seq)], instanceID: instanceID)
    }

    func clear(instanceID: String, upTo seq: UInt64) -> Bool {
        guard let newest = newestVersion(instanceID) else { return true }
        switch Self.read(newest.value) {
        case .unreadable: return false // a clear never touches what it cannot read
        case .readable(let existing?) where existing.seq > seq: return true
        case .readable: return retire(versions(instanceID).map(\.key))
        }
    }

    func replaceUnreadable(instanceID: String, with entry: JournalEntry?) -> Bool {
        guard let newest = newestVersion(instanceID), case .unreadable = Self.read(newest.value) else { return true }
        return install(entry.map { ["seq": NSNumber(value: $0.seq)] } ?? ["none": true], instanceID: instanceID)
    }

    private enum Read {
        case readable(JournalEntry?)
        case unreadable
    }

    private static func read(_ value: Any) -> Read {
        do { return .readable(try parse(value)) } catch { return .unreadable }
    }

    // MARK: Versions

    private struct Version {
        let key: String
        let number: Int
        let value: Any
    }

    private static func hash(_ instanceID: String) -> String {
        SHA256.hash(data: Data(instanceID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func versions(_ instanceID: String) -> [Version] {
        let hash = Self.hash(instanceID)
        let prefix = "journal.\(hash)."
        var found: [Version] = []
        if let legacy = defaults.object(forKey: "revoked.\(hash)") {
            found.append(Version(key: "revoked.\(hash)", number: 0, value: legacy))
        }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let number = Int(key.dropFirst(prefix.count)), number > 0 {
                found.append(Version(key: key, number: number, value: value))
            }
        }
        return found.sorted { $0.number < $1.number }
    }

    private func newestVersion(_ instanceID: String) -> Version? {
        versions(instanceID).last
    }

    /// `{seq}` → entry, `{none}` → no entry, a bare number → `.legacy`,
    /// anything else → corrupt.
    private static func parse(_ value: Any) throws(LicenseStoreError) -> JournalEntry? {
        if let dictionary = value as? [String: Any] {
            if dictionary["none"] as? Bool == true, dictionary.count == 1 { return nil }
            guard let number = dictionary["seq"] as? NSNumber, dictionary.count == 1, number.int64Value >= 0 else { throw .corrupt }
            return JournalEntry(seq: number.uint64Value)
        }
        if value is NSNumber { return .legacy }
        throw .corrupt
    }

    /// Writes `value` as the next version, flushes and reads it back; only
    /// then are older versions retired. On any failure the new version is
    /// removed again and nothing older changed.
    private func install(_ value: [String: Any], instanceID: String) -> Bool {
        let existing = versions(instanceID)
        let number = (existing.last?.number ?? 0) + 1
        let key = "journal.\(Self.hash(instanceID)).\(number)"
        defaults.set(value, forKey: key)
        guard defaults.synchronize(), let stored = defaults.object(forKey: key) as? [String: Any],
              NSDictionary(dictionary: stored).isEqual(to: value) else {
            defaults.removeObject(forKey: key)
            defaults.synchronize()
            return false
        }
        _ = retire(existing.map(\.key)) // best effort: the newest version is what counts
        return true
    }

    private func retire(_ keys: [String]) -> Bool {
        for key in keys { defaults.removeObject(forKey: key) }
        return defaults.synchronize() && keys.allSatisfy { defaults.object(forKey: $0) == nil }
    }
}
#endif
