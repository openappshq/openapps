import CryptoKit
import Foundation
@testable import OpenAppsLicensing
import Testing

/// The encrypted file store (LICENSING.md, "Record store") against a
/// temporary directory; the real Application Support is never touched.
@Suite("File record store")
struct FileRecordStoreTests {
    struct FixedDevice: DeviceIdentity {
        let uuid: String?
        func hardwareUUID() -> String? { uuid }
    }

    /// A throwaway base directory standing in for Application Support (the
    /// store creates `OpenApps/openreaction/records` below it), removed
    /// after the test with its modes restored first so the removal succeeds.
    final class Sandbox {
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
        func file(_ name: String) -> URL { records.appendingPathComponent(name) }
        func contents() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: records.path).sorted() }
    }

    /// The live system calls with any of them made to fail on demand.
    /// `directorySync` is the `fsync` of the records directory itself (the
    /// one after a rename or unlink); `ancestorSync` that of any directory
    /// above it.
    final class FailingSystem: @unchecked Sendable {
        enum Step { case write, fileSync, directorySync, ancestorSync, rename, unlink }
        private let lock = NSLock()
        private let records: URL
        private var failing: Set<Step> = []
        /// Steps armed to fail exactly once, after that many calls passed.
        private var failOnceAfter: [Step: Int] = [:]
        /// How often a failing step was hit.
        private(set) var hits: [Step: Int] = [:]
        /// How often each step was called, failing or not.
        private(set) var calls: [Step: Int] = [:]

        init(records: URL) {
            self.records = records
        }

        func fail(_ step: Step, _ on: Bool = true) {
            lock.withLock { if on { failing.insert(step) } else { failing.remove(step) } }
        }

        /// The step fails once, on its `passing + 1`th call from now.
        func failOnce(_ step: Step, afterPassing passing: Int) {
            lock.withLock { failOnceAfter[step] = passing }
        }

        private func shouldFail(_ step: Step) -> Bool {
            lock.withLock {
                calls[step, default: 0] += 1
                if let remaining = failOnceAfter[step] {
                    if remaining == 0 {
                        failOnceAfter[step] = nil
                        hits[step, default: 0] += 1
                        return true
                    }
                    failOnceAfter[step] = remaining - 1
                }
                guard failing.contains(step) else { return false }
                hits[step, default: 0] += 1
                return true
            }
        }

        /// Which sync a descriptor's `fsync` is: the records directory, another directory, or a file.
        private func syncStep(_ fd: Int32) -> Step {
            var status = stat()
            guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else { return .fileSync }
            var recordsStatus = stat()
            if stat(records.path, &recordsStatus) == 0, recordsStatus.st_dev == status.st_dev, recordsStatus.st_ino == status.st_ino {
                return .directorySync
            }
            return .ancestorSync
        }

        var system: RecordFileSystem {
            var system = RecordFileSystem.live
            system.write = { [self] fd, bytes, count in
                if shouldFail(.write) { errno = EIO; return -1 }
                return Darwin.write(fd, bytes, count)
            }
            system.fsync = { [self] fd in
                if shouldFail(syncStep(fd)) { errno = EIO; return -1 }
                return Darwin.fsync(fd)
            }
            system.renameat = { [self] from, fromName, to, toName in
                if shouldFail(.rename) { errno = EIO; return -1 }
                return Darwin.renameat(from, fromName, to, toName)
            }
            system.unlinkat = { [self] dirfd, name, flags in
                if shouldFail(.unlink) { errno = EIO; return -1 }
                return Darwin.unlinkat(dirfd, name, flags)
            }
            return system
        }
    }

    static let uuid = "11111111-2222-3333-4444-555555555555"
    static let otherUUID = "AAAAAAAA-0000-0000-0000-000000000000"

    func store(_ sandbox: Sandbox, uuid: String? = FileRecordStoreTests.uuid, appID: String = "openreaction", system: RecordFileSystem = .live) -> FileRecordStore {
        FileRecordStore(appID: appID, device: FixedDevice(uuid: uuid), baseDirectory: sandbox.root, system: system)
    }

    static let license = LicenseRecord(
        licenseKey: "KEY-1", instanceID: "inst_1", productID: "pdt_paid",
        activatedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_100),
        eventSeq: 3
    )
    static let trial = TrialRecord(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeenAt: Date(timeIntervalSince1970: 1_700_003_600),
        registered: true, fallbackDeviceID: nil
    )

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func isSymlink(_ url: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func isUnavailable(_ error: LicenseStoreError?) -> Bool {
        if case .unavailable? = error { return true }
        return false
    }

    static func isIndeterminate(_ error: LicenseStoreError?) -> Bool {
        if case .indeterminate? = error { return true }
        return false
    }

    /// The error a throwing call produced, or nil when it did not throw.
    static func failure<T>(_ body: () throws(LicenseStoreError) -> T) -> LicenseStoreError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    private func unavailable<T>(_ body: @autoclosure () throws(LicenseStoreError) -> T) -> Bool { Self.isUnavailable(Self.failure(body)) }
    private func indeterminate<T>(_ body: @autoclosure () throws(LicenseStoreError) -> T) -> Bool { Self.isIndeterminate(Self.failure(body)) }

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
        #expect(!FileManager.default.fileExists(atPath: sandbox.file(FileRecordStore.cleanupsFile).path))
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
        // Clearing what is not there is fine too, and creates nothing.
        try store.clearRecord()
        #expect(!FileManager.default.fileExists(atPath: sandbox.records.path))
        // Even the base directory may be missing.
        try FileManager.default.removeItem(at: sandbox.root)
        #expect(try store.loadRecord() == nil)
        try FileManager.default.createDirectory(at: sandbox.root, withIntermediateDirectories: true)
    }

    @Test func aDeletedRecordReadsAsAbsent() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        #expect(try store.loadRecord() == Self.license)
        try store.clearRecord()
        #expect(try store.loadRecord() == nil)
        try store.savePendingCleanups([PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")])
        try store.savePendingCleanups([])
        #expect(try store.loadPendingCleanups() == [])
    }

    // MARK: Format

    @Test func theFileStartsWithTheMagicAndHoldsNoPlaintext() throws {
        let sandbox = Sandbox()
        try store(sandbox).saveRecord(Self.license)
        let bytes = try Data(contentsOf: sandbox.file(FileRecordStore.licenseFile))
        let magic = Data(FileRecordStore.magic.utf8)
        #expect(magic.count == 19)
        #expect(bytes.prefix(magic.count) == magic)
        // magic + 12-byte nonce + ciphertext + 16-byte tag
        #expect(bytes.count > magic.count + 12 + 16)
        #expect(bytes.range(of: Data("KEY-1".utf8)) == nil)
        #expect(bytes.range(of: Data("inst_1".utf8)) == nil)
        #expect(bytes.range(of: Data("license_key".utf8)) == nil)
    }

    @Test func everySaveUsesAFreshNonce() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        let magic = FileRecordStore.magic.utf8.count
        let saves: [(String, () throws -> Void)] = [
            (FileRecordStore.licenseFile, { try store.saveRecord(Self.license) }),
            (FileRecordStore.trialFile, { try store.saveTrial(Self.trial) }),
            (FileRecordStore.cleanupsFile, { try store.savePendingCleanups([PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")]) }),
        ]
        for (file, save) in saves {
            try save()
            let first = try Data(contentsOf: sandbox.file(file))
            try save()
            let second = try Data(contentsOf: sandbox.file(file))
            #expect(first.count == second.count, Comment(rawValue: file))
            #expect(first[magic..<(magic + 12)] != second[magic..<(magic + 12)], "nonce repeated for \(file)")
            #expect(first[(magic + 12)...] != second[(magic + 12)...], "ciphertext repeated for \(file)")
        }
    }

    @Test func aDifferentMacCannotOpenTheFiles() throws {
        let sandbox = Sandbox()
        try store(sandbox, uuid: Self.otherUUID).saveRecord(Self.license)
        try store(sandbox, uuid: Self.otherUUID).saveTrial(Self.trial)
        let other = store(sandbox, uuid: "BBBBBBBB-0000-0000-0000-000000000000")
        #expect(throws: LicenseStoreError.corrupt) { try other.loadRecord() }
        #expect(throws: LicenseStoreError.corrupt) { try other.loadTrial() }
        // The files are left where they are: not replaced, not deleted.
        #expect(try store(sandbox, uuid: Self.otherUUID).loadRecord() == Self.license)
    }

    @Test func noHardwareUUIDStillOpensItsOwnFilesButNotAnotherMacs() throws {
        let sandbox = Sandbox()
        try store(sandbox, uuid: nil).saveTrial(Self.trial)
        #expect(try store(sandbox, uuid: nil).loadTrial() == Self.trial)
        #expect(throws: LicenseStoreError.corrupt) { try store(sandbox, uuid: Self.otherUUID).loadTrial() }
        // The stand-in is the fixed string, not an empty key.
        #expect(FileRecordStore.noHardwareUUID == "no-hardware-uuid")
    }

    @Test func aTamperedByteIsCorrupt() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        let url = sandbox.file(FileRecordStore.licenseFile)
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
        let url = sandbox.file(FileRecordStore.trialFile)

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
        try FileManager.default.copyItem(at: sandbox.file(FileRecordStore.trialFile), to: sandbox.file(FileRecordStore.licenseFile))
        #expect(throws: LicenseStoreError.corrupt) { try store.loadRecord() }
        #expect(try store.loadTrial() == Self.trial)
        // Another app's file copied into this app's place (or the other way
        // round): the app id is in the key and the AAD.
        let openklack = sandbox.root.appendingPathComponent("OpenApps/openklack/records", isDirectory: true)
        try FileManager.default.createDirectory(at: openklack, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sandbox.file(FileRecordStore.trialFile), to: openklack.appendingPathComponent(FileRecordStore.trialFile))
        #expect(throws: LicenseStoreError.corrupt) { try self.store(sandbox, appID: "openklack").loadTrial() }
    }

    @Test func aWellSealedFileThatIsNotJSONIsCorrupt() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // Sealed with this Mac's key for the license file, so the tag passes
        // and only the JSON decoding can refuse it.
        let key = SymmetricKey(data: FileRecordStore.deriveKey(appID: "openreaction", hardwareUUID: Self.uuid))
        let box = try AES.GCM.seal(Data("not json".utf8), using: key, authenticating: Data("openreaction:\(FileRecordStore.licenseFile)".utf8))
        try (Data(FileRecordStore.magic.utf8) + box.combined!).write(to: sandbox.file(FileRecordStore.licenseFile))
        #expect(throws: LicenseStoreError.corrupt) { try store.loadRecord() }
        #expect(try store.loadTrial() == Self.trial)
    }

    // MARK: Links and special files

    @Test func aDanglingSymlinkIsUnavailableNotAbsent() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license) // creates the directory
        let target = sandbox.root.appendingPathComponent("gone")
        try FileManager.default.createSymbolicLink(at: sandbox.file(FileRecordStore.trialFile), withDestinationURL: target)
        #expect(unavailable(try store.loadTrial()), "a dangling link must not read as 'no trial yet'")
        // Not replaced by a save either: the link is still a link, its target still absent.
        #expect(unavailable(try store.saveTrial(Self.trial)))
        #expect(try isSymlink(sandbox.file(FileRecordStore.trialFile)))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try sandbox.contents() == [FileRecordStore.licenseFile, FileRecordStore.trialFile], "no temporary file left")
    }

    @Test func aSymlinkToAValidRecordIsUnavailable() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // A real record elsewhere, linked into the records directory.
        let elsewhere = sandbox.root.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: sandbox.file(FileRecordStore.trialFile), to: elsewhere)
        let bytes = try Data(contentsOf: elsewhere)
        try FileManager.default.createSymbolicLink(at: sandbox.file(FileRecordStore.trialFile), withDestinationURL: elsewhere)
        #expect(unavailable(try store.loadTrial()), "a link is never followed, even to a good record")
        #expect(unavailable(try store.saveTrial(Self.trial)))
        // The linked file was neither replaced nor written through.
        #expect(try Data(contentsOf: elsewhere) == bytes)
        #expect(try isSymlink(sandbox.file(FileRecordStore.trialFile)))
        // Put back as a regular file, it reads.
        try FileManager.default.removeItem(at: sandbox.file(FileRecordStore.trialFile))
        try FileManager.default.moveItem(at: elsewhere, to: sandbox.file(FileRecordStore.trialFile))
        #expect(try store.loadTrial() == Self.trial)
    }

    @Test func aRecordsDirectoryThatIsASymlinkIsUnavailable() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // The whole directory moved away and linked back.
        let elsewhere = sandbox.root.appendingPathComponent("records-elsewhere")
        try FileManager.default.moveItem(at: sandbox.records, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: sandbox.records, withDestinationURL: elsewhere)
        #expect(unavailable(try store.loadTrial()))
        #expect(unavailable(try store.loadRecord()))
        #expect(unavailable(try store.saveTrial(Self.trial)))
        #expect(unavailable(try store.clearRecord()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [FileRecordStore.trialFile], "nothing written through the link")
        try FileManager.default.removeItem(at: sandbox.records)

        // A link higher up (`OpenApps`) is refused the same way.
        let openApps = sandbox.root.appendingPathComponent("OpenApps")
        try FileManager.default.removeItem(at: openApps)
        try FileManager.default.createSymbolicLink(at: openApps, withDestinationURL: sandbox.root.appendingPathComponent("nowhere"))
        #expect(unavailable(try store.loadTrial()))
        #expect(unavailable(try store.saveTrial(Self.trial)))
    }

    @Test func aFileWhereADirectoryShouldBeIsUnavailable() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try Data().write(to: sandbox.root.appendingPathComponent("OpenApps"))
        #expect(unavailable(try store.loadTrial()))
        #expect(unavailable(try store.saveTrial(Self.trial)))
    }

    @Test func aFIFOInTheRecordsPlaceIsUnavailableWithoutBlocking() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        #expect(mkfifo(sandbox.file(FileRecordStore.trialFile).path, 0o600) == 0)
        // No writer ever opens the FIFO: a blocking open would hang here.
        #expect(unavailable(try store.loadTrial()))
        #expect(unavailable(try store.saveTrial(Self.trial)))
    }

    // MARK: Availability and atomicity

    @Test func anUnreadableDirectoryIsUnavailableNotAbsent() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)
        #expect(chmod(sandbox.records.path, 0o000) == 0)
        defer { chmod(sandbox.records.path, 0o700) }

        #expect(unavailable(try store.loadRecord()), "an unreadable directory must never read as 'no license'")
        #expect(unavailable(try store.loadTrial()), "an unreadable directory must never read as 'no trial yet'")
        #expect(unavailable(try store.loadPendingCleanups()))
        #expect(unavailable(try store.saveTrial(Self.trial)))
        #expect(unavailable(try store.clearRecord()))
    }

    @Test func aFailedTemporaryFileLeavesTheOldFileAndNoTemporaryBehind() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        // Read-only directory: the temporary file cannot be created.
        #expect(chmod(sandbox.records.path, 0o500) == 0)
        defer { chmod(sandbox.records.path, 0o700) }

        var later = Self.trial
        later.lastSeenAt = later.lastSeenAt.addingTimeInterval(3_600)
        #expect(unavailable(try store.saveTrial(later)))

        chmod(sandbox.records.path, 0o700)
        #expect(try store.loadTrial() == Self.trial, "the old record survives a failed save")
        #expect(try sandbox.contents() == [FileRecordStore.trialFile], "no temporary file is left behind")
    }

    @Test(arguments: [FailingSystem.Step.write, .fileSync, .rename, .ancestorSync])
    func aFailureBeforeTheRenameIsUnavailableAndLeavesTheOldFile(step: FailingSystem.Step) throws {
        let sandbox = Sandbox()
        let failing = FailingSystem(records: sandbox.records)
        let store = store(sandbox, system: failing.system)
        try store.saveTrial(Self.trial)
        let before = try Data(contentsOf: sandbox.file(FileRecordStore.trialFile))

        failing.fail(step)
        var later = Self.trial
        later.lastSeenAt = later.lastSeenAt.addingTimeInterval(3_600)
        #expect(unavailable(try store.saveTrial(later)), "\(step)")
        #expect(failing.hits[step] == 1)
        #expect(try Data(contentsOf: sandbox.file(FileRecordStore.trialFile)) == before, "\(step): the old file is byte-for-byte what it was")
        #expect(try sandbox.contents() == [FileRecordStore.trialFile], "\(step): no temporary file left")

        failing.fail(step, false)
        try store.saveTrial(later)
        #expect(try store.loadTrial() == later)
    }

    @Test func aFailedDirectorySyncAfterTheRenameIsIndeterminateAndTheNewFileIsInPlace() throws {
        let sandbox = Sandbox()
        let failing = FailingSystem(records: sandbox.records)
        let store = store(sandbox, system: failing.system)
        try store.saveRecord(Self.license)

        failing.fail(.directorySync)
        var updated = Self.license
        updated.eventSeq = 4
        #expect(indeterminate(try store.saveRecord(updated)))
        #expect(failing.hits[.directorySync] == 1)
        // The rename happened: what the directory shows is the new, complete record.
        #expect(try self.store(sandbox).loadRecord() == updated)
        #expect(try sandbox.contents() == [FileRecordStore.licenseFile], "no temporary file left")

        // The same write again, once the disk answers: durable, no error.
        failing.fail(.directorySync, false)
        try store.saveRecord(updated)
        #expect(try store.loadRecord() == updated)
    }

    @Test func aFailedDirectorySyncAfterADeleteIsIndeterminate() throws {
        let sandbox = Sandbox()
        let failing = FailingSystem(records: sandbox.records)
        let store = store(sandbox, system: failing.system)
        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)

        failing.fail(.directorySync)
        #expect(indeterminate(try store.clearRecord()))
        #expect(try self.store(sandbox).loadRecord() == nil) // the entry is gone from the directory
        #expect(try store.loadTrial() == Self.trial)

        // A failed unlink itself is an ordinary failure: the file stays.
        failing.fail(.directorySync, false)
        try store.saveRecord(Self.license)
        failing.fail(.unlink)
        #expect(unavailable(try store.clearRecord()))
        #expect(try store.loadRecord() == Self.license)

        // Retried, the delete is idempotent and completes.
        failing.fail(.unlink, false)
        try store.clearRecord()
        try store.clearRecord()
        #expect(try store.loadRecord() == nil)
    }

    @Test func everyAncestorIsSyncedOnEveryWriteSoAFailedOneIsMadeUpForByTheRetry() throws {
        let sandbox = Sandbox()
        let failing = FailingSystem(records: sandbox.records)
        let store = store(sandbox, system: failing.system)
        // First save: the base's parent syncs, `OpenApps` is created, then
        // syncing the base (its parent) fails.
        failing.failOnce(.ancestorSync, afterPassing: 1)
        #expect(unavailable(try store.saveTrial(Self.trial)))
        #expect(failing.hits[.ancestorSync] == 1)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("OpenApps").path), "the directory exists, unsynced")
        #expect(!FileManager.default.fileExists(atPath: sandbox.records.path))

        // The retry — from a fresh instance, as after a restart — finds it and
        // syncs the base's parent, the base, `OpenApps` and the app directory anyway.
        let before = failing.calls[.ancestorSync] ?? 0
        try self.store(sandbox, system: failing.system).saveTrial(Self.trial)
        #expect((failing.calls[.ancestorSync] ?? 0) - before == 4, "every ancestor is synced")
        #expect(try store.loadTrial() == Self.trial)

        // And on a later write into an existing chain, all four again.
        let later = failing.calls[.ancestorSync] ?? 0
        try store.saveRecord(Self.license)
        #expect((failing.calls[.ancestorSync] ?? 0) - later == 4)
        // Reads sync nothing.
        let reads = failing.calls[.ancestorSync] ?? 0
        _ = try store.loadRecord()
        #expect(failing.calls[.ancestorSync] == reads)
    }

    @Test func aMissingBaseDirectoryIsCreatedAndSyncedInItsParent() throws {
        let sandbox = Sandbox()
        let failing = FailingSystem(records: sandbox.records)
        let store = store(sandbox, system: failing.system)
        try FileManager.default.removeItem(at: sandbox.root)
        defer { try? FileManager.default.createDirectory(at: sandbox.root, withIntermediateDirectories: true) }
        try store.saveTrial(Self.trial)
        #expect(failing.calls[.ancestorSync] == 4)
        #expect(try store.loadTrial() == Self.trial)
        #expect(try mode(sandbox.records) == 0o700)

        // A failed sync of the base's parent is an ordinary failure; the
        // retry finds the base and syncs its parent again.
        try FileManager.default.removeItem(at: sandbox.root)
        failing.fail(.ancestorSync)
        #expect(unavailable(try store.saveTrial(Self.trial)))
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("OpenApps").path))
        failing.fail(.ancestorSync, false)
        let before = failing.calls[.ancestorSync] ?? 0
        try store.saveTrial(Self.trial)
        #expect((failing.calls[.ancestorSync] ?? 0) - before == 4)
        #expect(try store.loadTrial() == Self.trial)
    }

    @Test func aSuccessfulWriteLeavesNoTemporaryFile() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveTrial(Self.trial)
        try store.saveTrial(Self.trial)
        try store.saveRecord(Self.license)
        #expect(try sandbox.contents() == [FileRecordStore.licenseFile, FileRecordStore.trialFile])
    }

    // MARK: Deletion

    @Test func clearRecordDeletesOnlyTheLicense() throws {
        let sandbox = Sandbox()
        let store = store(sandbox)
        try store.saveRecord(Self.license)
        try store.saveTrial(Self.trial)
        try store.savePendingCleanups([PendingCleanup(licenseKey: "KEY-0", instanceID: "inst_0")])
        let trialBytes = try Data(contentsOf: sandbox.file(FileRecordStore.trialFile))

        try store.clearRecord()
        #expect(try store.loadRecord() == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.file(FileRecordStore.licenseFile).path))
        // The trial file is byte-for-byte what it was; the cleanups stay owed.
        #expect(try Data(contentsOf: sandbox.file(FileRecordStore.trialFile)) == trialBytes)
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
            #expect(try mode(sandbox.file(file)) == 0o600, Comment(rawValue: file))
        }
        // The directories above it were created with the same mode.
        #expect(try mode(sandbox.records.deletingLastPathComponent()) == 0o700)
        #expect(try mode(sandbox.root.appendingPathComponent("OpenApps")) == 0o700)
    }

    @Test func theDefaultDirectoryIsUnderApplicationSupport() {
        let url = FileRecordStore.defaultDirectory(appID: "openreaction")
        #expect(url.path.hasSuffix("/Library/Application Support/OpenApps/openreaction/records"))
        let store = FileRecordStore(appID: "openreaction", device: FixedDevice(uuid: nil))
        #expect(store.directory == url)
    }
}
