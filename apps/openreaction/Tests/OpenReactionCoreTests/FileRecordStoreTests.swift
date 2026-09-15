import CryptoKit
import Foundation
import OpenReactionCore
import Testing

/// The encrypted file store (LICENSING.md, "Record store") against a
/// temporary directory; the real Application Support is never touched.
@Suite("File record store")
struct FileRecordStoreTests {
    private struct FixedDevice: DeviceIdentity {
        let uuid: String?
        func hardwareUUID() -> String? { uuid }
    }

    /// A throwaway `records` directory (not created: the store does that),
    /// removed after the test, with its modes restored first so the removal
    /// succeeds.
    private final class Sandbox {
        let root: URL
        let records: URL
        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("openreaction-record-store-\(UUID().uuidString)", isDirectory: true)
            records = root.appendingPathComponent("OpenApps/openreaction/records", isDirectory: true)
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit {
            chmod(records.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func store(_ sandbox: Sandbox, uuid: String? = "11111111-2222-3333-4444-555555555555", appID: String = "openreaction") -> FileRecordStore {
        FileRecordStore(appID: appID, device: FixedDevice(uuid: uuid), directory: sandbox.records)
    }

    private static let license = LicenseRecord(
        licenseKey: "KEY-1", instanceID: "inst_1", productID: "pdt_paid",
        activatedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_100),
        eventSeq: 3
    )
    private static let trial = TrialRecord(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeenAt: Date(timeIntervalSince1970: 1_700_003_600),
        registered: true, fallbackDeviceID: nil
    )

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: Round trips

    @Test func bothRecordsAndTheCleanupsRoundTrip() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        #expect(try store.loadRecord() == nil)
        #expect(try store.loadTrial() == nil)
        #expect(try store.loadPendingCleanups() == [])

        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)
        let cleanups = [PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")]
        try store.savePendingCleanups(cleanups)

        // Another instance over the same directory and Mac reads them back.
        let again = self.store(sandbox)
        #expect(try again.loadRecord() == Self.license)
        #expect(try again.loadTrial() == Self.trial)
        #expect(try again.loadPendingCleanups() == cleanups)

        // A save replaces the record in place.
        var updated = Self.license
        updated.eventSeq = 4
        try store.saveRecord(updated)
        #expect(try again.loadRecord()?.eventSeq == 4)

        // Nothing owed removes the cleanups file; the read is "none".
        try store.savePendingCleanups([])
        #expect(!FileManager.default.fileExists(atPath: sandbox.records.appendingPathComponent(FileRecordStore.cleanupsFile).path))
        #expect(try store.loadPendingCleanups() == [])
    }

    @Test func aMissingFileOrDirectoryIsPositivelyAbsent() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        // The records directory does not exist yet: still "not found", never an error.
        #expect(!FileManager.default.fileExists(atPath: sandbox.records.path))
        #expect(try store.loadRecord() == nil)
        #expect(try store.loadTrial() == nil)
        #expect(try store.loadPendingCleanups() == [])
        // Clearing what is not there is fine too.
        try store.clearRecord()
    }

    // MARK: Format

    @Test func theFileStartsWithTheMagicAndHoldsNoPlaintext() throws {
        let sandbox = Sandbox()
        try store(sandbox).saveRecord(Self.license)
        let bytes = try Data(contentsOf: sandbox.records.appendingPathComponent(FileRecordStore.licenseFile))
        let magic = Data(FileRecordStore.magic.utf8)
        #expect(bytes.prefix(magic.count) == magic)
        // magic + 12-byte nonce + ciphertext + 16-byte tag
        #expect(bytes.count > magic.count + 12 + 16)
        #expect(bytes.range(of: Data("KEY-1".utf8)) == nil)
        #expect(bytes.range(of: Data("inst_1".utf8)) == nil)
        #expect(bytes.range(of: Data("license_key".utf8)) == nil)
    }

    @Test func aDifferentMacCannotOpenTheFiles() throws {
        let sandbox = Sandbox()
        try store(sandbox, uuid: "AAAAAAAA-0000-0000-0000-000000000000").saveRecord(Self.license)
        try store(sandbox, uuid: "AAAAAAAA-0000-0000-0000-000000000000").saveTrial(Self.trial)
        let other = store(sandbox, uuid: "BBBBBBBB-0000-0000-0000-000000000000")
        #expect(throws: LicenseStoreError.corrupt) { try other.loadRecord() }
        #expect(throws: LicenseStoreError.corrupt) { try other.loadTrial() }
        // The files are left where they are: not replaced, not deleted.
        #expect(try store(sandbox, uuid: "AAAAAAAA-0000-0000-0000-000000000000").loadRecord() == Self.license)
    }

    @Test func noHardwareUUIDStillOpensItsOwnFilesButNotAnotherMacs() throws {
        let sandbox = Sandbox()
        try store(sandbox, uuid: nil).saveTrial(Self.trial)
        #expect(try store(sandbox, uuid: nil).loadTrial() == Self.trial)
        #expect(throws: LicenseStoreError.corrupt) { try store(sandbox, uuid: "AAAAAAAA-0000-0000-0000-000000000000").loadTrial() }
        // The stand-in is the fixed string, not an empty key.
        #expect(FileRecordStore.noHardwareUUID == "no-hardware-uuid")
    }

    @Test func aTamperedByteIsCorrupt() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        let url = sandbox.records.appendingPathComponent(FileRecordStore.licenseFile)
        var bytes = try Data(contentsOf: url)
        // Flip one bit in the ciphertext, past the magic and the nonce.
        let index = FileRecordStore.magic.utf8.count + 12 + 2
        bytes[index] ^= 0x01
        try bytes.write(to: url)
        #expect(throws: LicenseStoreError.corrupt) { try store.loadRecord() }
    }

    @Test func theWrongMagicOrATruncatedFileIsCorrupt() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        let url = sandbox.records.appendingPathComponent(FileRecordStore.trialFile)

        try Data("{\"started_at\":1}".utf8).write(to: url) // plain JSON from a hand edit
        #expect(throws: LicenseStoreError.corrupt) { try store.loadTrial() }

        try Data("openapps-records-v0".utf8).write(to: url) // another version
        #expect(throws: LicenseStoreError.corrupt) { try store.loadTrial() }

        try Data(FileRecordStore.magic.utf8).write(to: url) // magic only
        #expect(throws: LicenseStoreError.corrupt) { try store.loadTrial() }

        try (Data(FileRecordStore.magic.utf8) + Data(repeating: 0, count: 20)).write(to: url) // too short for a box
        #expect(throws: LicenseStoreError.corrupt) { try store.loadTrial() }

        try Data().write(to: url) // empty
        #expect(throws: LicenseStoreError.corrupt) { try store.loadTrial() }
    }

    @Test func aFileRenamedIntoAnotherRecordOrAppIsCorrupt() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // The trial file copied over the license file: the file name is authenticated.
        let trialURL = sandbox.records.appendingPathComponent(FileRecordStore.trialFile)
        let licenseURL = sandbox.records.appendingPathComponent(FileRecordStore.licenseFile)
        try FileManager.default.copyItem(at: trialURL, to: licenseURL)
        #expect(throws: LicenseStoreError.corrupt) { try store.loadRecord() }
        #expect(try store.loadTrial() == Self.trial)
        // Another app's store over the same directory: the app id is in the key and the AAD.
        #expect(throws: LicenseStoreError.corrupt) { try self.store(sandbox, appID: "openklack").loadTrial() }
    }

    @Test func aWellSealedFileThatIsNotJSONIsCorrupt() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // Sealed with this Mac's key for the license file, so the tag passes
        // and only the JSON decoding can refuse it.
        let key = SymmetricKey(data: FileRecordStore.deriveKey(appID: "openreaction", hardwareUUID: "11111111-2222-3333-4444-555555555555"))
        let box = try AES.GCM.seal(Data("not json".utf8), using: key, authenticating: Data("openreaction:\(FileRecordStore.licenseFile)".utf8))
        try (Data(FileRecordStore.magic.utf8) + box.combined!).write(to: sandbox.records.appendingPathComponent(FileRecordStore.licenseFile))
        #expect(throws: LicenseStoreError.corrupt) { try store.loadRecord() }
        #expect(try store.loadTrial() == Self.trial)
    }

    // MARK: Availability and atomicity

    @Test func anUnreadableDirectoryIsUnavailableNotAbsent() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)
        #expect(chmod(sandbox.records.path, 0o000) == 0)
        defer { chmod(sandbox.records.path, 0o700) }

        var unavailable = false
        do { _ = try store.loadRecord() } catch { if case .unavailable = error { unavailable = true } }
        #expect(unavailable, "an unreadable directory must never read as 'no license'")
        unavailable = false
        do { _ = try store.loadTrial() } catch { if case .unavailable = error { unavailable = true } }
        #expect(unavailable, "an unreadable directory must never read as 'no trial yet'")
        unavailable = false
        do { _ = try store.loadPendingCleanups() } catch { if case .unavailable = error { unavailable = true } }
        #expect(unavailable)

        // A save into it fails and says so.
        do {
            try store.saveTrial(Self.trial)
            Issue.record("saving into an unreadable directory must fail")
        } catch {
            guard case .unavailable = error else { Issue.record("expected .unavailable, got \(error)"); return }
        }
    }

    @Test func aFailedWriteLeavesTheOldFileAndNoTemporaryBehind() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // Read-only directory: the temporary file cannot be created.
        #expect(chmod(sandbox.records.path, 0o500) == 0)
        defer { chmod(sandbox.records.path, 0o700) }

        var later = Self.trial
        later.lastSeenAt = later.lastSeenAt.addingTimeInterval(3_600)
        var failed = false
        do { try store.saveTrial(later) } catch { if case .unavailable = error { failed = true } }
        #expect(failed)

        chmod(sandbox.records.path, 0o700)
        #expect(try store.loadTrial() == Self.trial, "the old record survives a failed save")
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.records.path)
        #expect(contents == [FileRecordStore.trialFile], "no temporary file is left behind: \(contents)")
    }

    @Test func aSuccessfulWriteLeavesNoTemporaryFile() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        try store.saveTrial(Self.trial)
        try store.saveRecord(Self.license)
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.records.path).sorted()
        #expect(contents == [FileRecordStore.licenseFile, FileRecordStore.trialFile])
    }

    // MARK: Deletion

    @Test func clearRecordDeletesOnlyTheLicense() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)
        try store.savePendingCleanups([PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")])
        let trialBytes = try Data(contentsOf: sandbox.records.appendingPathComponent(FileRecordStore.trialFile))

        try store.clearRecord()
        #expect(try store.loadRecord() == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.records.appendingPathComponent(FileRecordStore.licenseFile).path))
        // The trial file is byte-for-byte what it was; the cleanups stay owed.
        #expect(try Data(contentsOf: sandbox.records.appendingPathComponent(FileRecordStore.trialFile)) == trialBytes)
        #expect(try store.loadTrial() == Self.trial)
        #expect(try store.loadPendingCleanups().count == 1)

        // Clearing twice is fine.
        try store.clearRecord()
    }

    // MARK: Modes

    @Test func theDirectoryIs0700AndTheFiles0600() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)
        try store.savePendingCleanups([PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")])
        #expect(try mode(sandbox.records) == 0o700)
        for file in [FileRecordStore.licenseFile, FileRecordStore.trialFile, FileRecordStore.cleanupsFile] {
            #expect(try mode(sandbox.records.appendingPathComponent(file)) == 0o600, Comment(rawValue: file))
        }
        // The directories above it were created with the same mode.
        #expect(try mode(sandbox.records.deletingLastPathComponent()) == 0o700)
    }

    @Test func theDefaultDirectoryIsUnderApplicationSupport() {
        let url = FileRecordStore.defaultDirectory(appID: "openreaction")
        #expect(url.path.hasSuffix("/Library/Application Support/OpenApps/openreaction/records"))
    }
}
