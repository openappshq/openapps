#if OPENAPPS_LICENSING
import Foundation
import OpenReactionCore
import Security

/// The license record as a generic-password Keychain item, plus the
/// activations still owed a deactivation as a second.
/// Service `space.openapps.openreaction.license`, this device only.
///
/// Every SecItem status is checked: "not found" is an absent item, anything
/// else is reported, so a locked or denied Keychain never looks like a
/// successful save or a missing license.
struct KeychainLicenseStore: LicenseStore {
    static let service = "space.openapps.openreaction.license"
    private static let recordAccount = "record"
    private static let cleanupsAccount = "pending_cleanups"
    private let keychain = KeychainItems(service: KeychainLicenseStore.service)

    func loadRecord() throws(LicenseStoreError) -> LicenseRecord? {
        guard let data = try keychain.read(account: Self.recordAccount) else { return nil }
        guard let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) else { throw .corrupt }
        return record
    }

    func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
        guard let data = try? JSONEncoder().encode(record) else { throw .corrupt }
        try keychain.write(data, account: Self.recordAccount)
    }

    func clearRecord() throws(LicenseStoreError) {
        try keychain.delete(account: Self.recordAccount)
    }

    func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] {
        guard let data = try keychain.read(account: Self.cleanupsAccount) else { return [] }
        guard let cleanups = try? JSONDecoder().decode([PendingCleanup].self, from: data) else { throw .corrupt }
        return cleanups
    }

    func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {
        if cleanups.isEmpty {
            try keychain.delete(account: Self.cleanupsAccount)
            return
        }
        guard let data = try? JSONEncoder().encode(cleanups) else { throw .corrupt }
        try keychain.write(data, account: Self.cleanupsAccount)
    }
}

/// The trial record as its own generic-password item, service
/// `space.openapps.openreaction.trial`, this device only. The app never
/// deletes it.
struct KeychainTrialStore: TrialStore {
    static let service = "space.openapps.openreaction.trial"
    private static let account = "record"
    private let keychain: KeychainItems

    init(service: String = KeychainTrialStore.service) {
        keychain = KeychainItems(service: service)
    }

    func loadTrial() throws(LicenseStoreError) -> TrialRecord? {
        guard let data = try keychain.read(account: Self.account) else { return nil }
        guard let trial = try? JSONDecoder().decode(TrialRecord.self, from: data) else { throw .corrupt }
        return trial
    }

    func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError) {
        guard let data = try? JSONEncoder().encode(trial) else { throw .corrupt }
        try keychain.write(data, account: Self.account)
    }
}

/// Generic-password items under one service.
struct KeychainItems: Sendable {
    let service: String

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// nil only when the item positively does not exist.
    func read(account: String) throws(LicenseStoreError) -> Data? {
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
            throw .unavailable(Self.describe(status))
        }
    }

    func write(_ data: Data, account: String) throws(LicenseStoreError) {
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
            guard added == errSecSuccess else { throw .unavailable(Self.describe(added)) }
        default:
            throw .unavailable(Self.describe(updated))
        }
    }

    func delete(account: String) throws(LicenseStoreError) {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .unavailable(Self.describe(status)) }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
#endif
