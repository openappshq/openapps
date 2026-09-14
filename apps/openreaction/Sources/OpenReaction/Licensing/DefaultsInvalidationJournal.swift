#if OPENAPPS_LICENSING
import CryptoKit
import Foundation
import OpenReactionCore

/// The invalidation journal as plain preferences: nothing secret is in it.
/// Each entry is `revoked.<SHA-256 of the instance id>` → the time Dodo
/// answered `valid: false`. It exists so a revocation the Keychain refused
/// to store still holds after a restart; it is cleared once the revoked
/// record is durable, on `valid: true` for that activation, or when the
/// activation is replaced or removed.
struct DefaultsInvalidationJournal: InvalidationJournal, @unchecked Sendable {
    static let suiteName = "space.openapps.openreaction.license"
    /// UserDefaults is thread-safe; the manager only ever calls from the main actor.
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: DefaultsInvalidationJournal.suiteName)) {
        self.defaults = defaults ?? .standard
    }

    func revokedAt(instanceID: String) -> Date? {
        guard let seconds = defaults.object(forKey: Self.key(instanceID)) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func record(instanceID: String, revokedAt: Date) -> Bool {
        let key = Self.key(instanceID)
        defaults.set(revokedAt.timeIntervalSince1970, forKey: key)
        // Flushed before the Keychain is even tried, and read back: only a
        // value that is on disk counts as protection.
        return defaults.synchronize() && defaults.object(forKey: key) as? Double == revokedAt.timeIntervalSince1970
    }

    func clear(instanceID: String) -> Bool {
        let key = Self.key(instanceID)
        defaults.removeObject(forKey: key)
        return defaults.synchronize() && defaults.object(forKey: key) == nil
    }

    private static func key(_ instanceID: String) -> String {
        let digest = SHA256.hash(data: Data(instanceID.utf8))
        return "revoked." + digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
