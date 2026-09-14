#if OPENAPPS_LICENSING
import Foundation
import OpenReactionCore
import Security

/// The license record as a generic-password Keychain item, plus the
/// trial-used flag as a second item that survives removing the record, and
/// the activations still owed a deactivation as a third.
/// Service `space.openapps.openreaction.license`, this device only.
///
/// Every SecItem status is checked: "not found" is an absent item, anything
/// else is reported, so a locked or denied Keychain never looks like a
/// successful save or a missing license.
struct KeychainLicenseStore: LicenseStore {
    static let service = "space.openapps.openreaction.license"
    private static let recordAccount = "record"
    private static let trialAccount = "trial_used"
    private static let cleanupsAccount = "pending_cleanups"

    func loadRecord() throws(LicenseStoreError) -> LicenseRecord? {
        guard let data = try Self.read(account: Self.recordAccount) else { return nil }
        guard let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) else { throw .corrupt }
        return record
    }

    func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
        guard let data = try? JSONEncoder().encode(record) else { throw .corrupt }
        try Self.write(data, account: Self.recordAccount)
    }

    func clearRecord() throws(LicenseStoreError) {
        try Self.delete(account: Self.recordAccount)
    }

    func loadTrialUsed() throws(LicenseStoreError) -> Bool {
        try Self.read(account: Self.trialAccount) != nil
    }

    func markTrialUsed() throws(LicenseStoreError) {
        try Self.write(Data("1".utf8), account: Self.trialAccount)
    }

    func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] {
        guard let data = try Self.read(account: Self.cleanupsAccount) else { return [] }
        guard let cleanups = try? JSONDecoder().decode([PendingCleanup].self, from: data) else { throw .corrupt }
        return cleanups
    }

    func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {
        if cleanups.isEmpty {
            try Self.delete(account: Self.cleanupsAccount)
            return
        }
        guard let data = try? JSONEncoder().encode(cleanups) else { throw .corrupt }
        try Self.write(data, account: Self.cleanupsAccount)
    }

    // MARK: - SecItem

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) throws(LicenseStoreError) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .corrupt }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw .unavailable(describe(status))
        }
    }

    private static func write(_ data: Data, account: String) throws(LicenseStoreError) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query(account: account)
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw .unavailable(describe(added)) }
        default:
            throw .unavailable(describe(updated))
        }
    }

    private static func delete(account: String) throws(LicenseStoreError) {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .unavailable(describe(status)) }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
#endif
