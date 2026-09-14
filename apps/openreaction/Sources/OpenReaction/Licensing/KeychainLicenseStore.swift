#if OPENAPPS_LICENSING
import Foundation
import OpenReactionCore
import Security

/// The license record as a generic-password Keychain item, plus the
/// trial-used flag as a second item that survives removing the record.
/// Service `space.openapps.openreaction.license`, this device only.
struct KeychainLicenseStore: LicenseStore {
    static let service = "space.openapps.openreaction.license"
    private static let recordAccount = "record"
    private static let trialAccount = "trial_used"

    func loadRecord() -> LicenseRecord? {
        guard let data = Self.read(account: Self.recordAccount) else { return nil }
        return try? JSONDecoder().decode(LicenseRecord.self, from: data)
    }

    func saveRecord(_ record: LicenseRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        Self.write(data, account: Self.recordAccount)
    }

    func clearRecord() {
        Self.delete(account: Self.recordAccount)
    }

    var trialUsed: Bool {
        Self.read(account: Self.trialAccount) != nil
    }

    func markTrialUsed() {
        Self.write(Data("1".utf8), account: Self.trialAccount)
    }

    // MARK: - SecItem

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: account)
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
#endif
