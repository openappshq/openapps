import CryptoKit
import Foundation

/// The license and trial records as encrypted files the app owns
/// (LICENSING.md, "Record store"): `~/Library/Application Support/OpenApps/
/// <app id>/records/`, one file per record — `license`, `trial`, and
/// `cleanups` for the activations still owed a deactivation.
///
/// Never the Keychain: with a self-signed certificate any change of signing
/// identity makes macOS ask for the app's own Keychain items on every launch,
/// and a file never prompts. Items from releases before 0.1.2 are left where
/// they are and never read, written or deleted.
///
/// Each file is the ASCII magic `openapps-records-v1`, then AES-256-GCM
/// (a random 12-byte nonce, the ciphertext, the 16-byte tag) over the
/// record's JSON, authenticating `<app id>:<file name>` as well so one file
/// cannot be renamed into another. The key is HKDF-SHA256 of the Mac's
/// hardware UUID (or `no-hardware-uuid` when it cannot be read) with the
/// info `openapps-records-v1:<app id>`; nothing about it is stored, so a copy
/// on another Mac cannot be opened. The source is public, so this stops
/// casual reading, editing and copying, not a determined local user — the
/// limit the design already accepts.
///
/// Reads report what they found: no entry at all is *absent* (nil); a
/// directory or file that cannot be opened or read, a symlink or anything
/// but a regular file in the record's place is `.unavailable`; a wrong magic,
/// a failed tag or undecodable JSON is `.corrupt`. Both errors are storage
/// errors to the manager — no new trial, no registry call, nothing
/// overwritten. Every path below the support directory is walked with
/// `openat` on a verified directory descriptor and `O_NOFOLLOW`, so a link
/// planted in the chain is refused rather than followed.
///
/// Writes are durable before they are reported: a temporary file in the
/// records directory, `fsync`, `rename` over the old file, then `fsync` of
/// the directory. A failure before the rename is `.unavailable` and leaves
/// the old file exactly as it was. After the rename only the directory sync
/// can fail; that is `.indeterminate`: the new, complete file is what the
/// directory shows, the disk holds the old or the new one, and the manager
/// keeps the new state, keeps its journal protection and repeats the same
/// write on the next tick. A deletion is `unlink` then the same directory
/// `fsync`, with the same two outcomes.
public struct FileRecordStore: LicenseStore, TrialStore, Sendable {
    /// The format tag every file starts with.
    public static let magic = "openapps-records-v1"
    public static let licenseFile = "license"
    public static let trialFile = "trial"
    public static let cleanupsFile = "cleanups"
    /// Stands in for the hardware UUID in the key when it cannot be read.
    public static let noHardwareUUID = "no-hardware-uuid"

    /// `~/Library/Application Support` (or what a test passes instead).
    public let baseDirectory: URL
    private let appID: String
    /// The derived key's bytes; a `SymmetricKey` is built per operation.
    private let keyData: Data
    /// The system calls, replaceable in tests to make a step fail.
    let system: RecordFileSystem

    /// - Parameters:
    ///   - appID: Salts the key and the authenticated data (`openreaction`).
    ///   - device: The hardware UUID the key derives from, read once here.
    ///   - baseDirectory: Where `OpenApps/<app id>/records` lives; the user's
    ///     Application Support by default. Tests pass a temporary one.
    public init(appID: String, device: any DeviceIdentity, baseDirectory: URL? = nil) {
        self.init(appID: appID, device: device, baseDirectory: baseDirectory, system: .live)
    }

    init(appID: String, device: any DeviceIdentity, baseDirectory: URL?, system: RecordFileSystem) {
        self.appID = appID
        self.baseDirectory = baseDirectory ?? Self.applicationSupport
        self.system = system
        keyData = Self.deriveKey(appID: appID, hardwareUUID: device.hardwareUUID())
    }

    /// `<base>/OpenApps/<app id>/records`.
    public var directory: URL {
        Self.relativeComponents(appID: appID).reduce(baseDirectory) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// `~/Library/Application Support/OpenApps/<app id>/records`.
    public static func defaultDirectory(appID: String) -> URL {
        relativeComponents(appID: appID).reduce(applicationSupport) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// The directories below the base, each opened without following links.
    private static func relativeComponents(appID: String) -> [String] {
        ["OpenApps", appID, "records"]
    }

    /// HKDF-SHA256 of the UUID (or `no-hardware-uuid`), info
    /// `openapps-records-v1:<app id>`, 32 bytes. No salt: the input is
    /// already unique per Mac and the info per app. Public so the format
    /// can be checked from outside; the app never stores the result.
    public static func deriveKey(appID: String, hardwareUUID: String?) -> Data {
        let material = SymmetricKey(data: Data((hardwareUUID ?? noHardwareUUID).utf8))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, info: Data("\(magic):\(appID)".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: LicenseStore

    public func loadRecord() throws(LicenseStoreError) -> LicenseRecord? {
        try load(LicenseRecord.self, file: Self.licenseFile)
    }

    public func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
        try save(record, file: Self.licenseFile)
    }

    /// Deletes `license` only; the trial record is never deleted.
    public func clearRecord() throws(LicenseStoreError) {
        try delete(file: Self.licenseFile)
    }

    public func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] {
        try load([PendingCleanup].self, file: Self.cleanupsFile) ?? []
    }

    /// An empty list removes the file, so "nothing owed" reads as absent.
    public func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {
        if cleanups.isEmpty {
            try delete(file: Self.cleanupsFile)
        } else {
            try save(cleanups, file: Self.cleanupsFile)
        }
    }

    // MARK: TrialStore

    public func loadTrial() throws(LicenseStoreError) -> TrialRecord? {
        try load(TrialRecord.self, file: Self.trialFile)
    }

    public func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError) {
        try save(trial, file: Self.trialFile)
    }

    // MARK: Records

    private func load<Record: Decodable>(_ type: Record.Type, file: String) throws(LicenseStoreError) -> Record? {
        guard let bytes = try readFile(file) else { return nil }
        let json = try open(bytes, file: file)
        guard let record = try? JSONDecoder().decode(type, from: json) else { throw .corrupt }
        return record
    }

    private func save<Record: Encodable>(_ record: Record, file: String) throws(LicenseStoreError) {
        guard let json = try? JSONEncoder().encode(record) else { throw .corrupt }
        try writeFile(file, seal(json, file: file))
    }

    // MARK: Format

    private var key: SymmetricKey { SymmetricKey(data: keyData) }
    private var magicBytes: Data { Data(Self.magic.utf8) }
    private func authenticatedData(file: String) -> Data { Data("\(appID):\(file)".utf8) }

    /// magic ‖ nonce ‖ ciphertext ‖ tag.
    private func seal(_ json: Data, file: String) throws(LicenseStoreError) -> Data {
        guard let box = try? AES.GCM.seal(json, using: key, nonce: AES.GCM.Nonce(), authenticating: authenticatedData(file: file)),
              let combined = box.combined else { throw .unavailable("couldn’t encrypt the \(file) record") }
        return magicBytes + combined
    }

    /// Anything that is not a file this store wrote for this app, file name
    /// and Mac is corrupt: the wrong magic, a truncated body, a tag that
    /// fails (another key, another file's name, an edited byte).
    private func open(_ bytes: Data, file: String) throws(LicenseStoreError) -> Data {
        let magic = magicBytes
        guard bytes.count > magic.count, bytes.prefix(magic.count) == magic else { throw .corrupt }
        guard let box = try? AES.GCM.SealedBox(combined: bytes.dropFirst(magic.count)),
              let json = try? AES.GCM.open(box, using: key, authenticating: authenticatedData(file: file)) else { throw .corrupt }
        return json
    }

    // MARK: Files

    /// An open descriptor, closed when this goes away.
    private final class Descriptor {
        let fd: Int32
        let system: RecordFileSystem
        init(_ fd: Int32, system: RecordFileSystem) {
            self.fd = fd
            self.system = system
        }
        deinit { _ = system.close(fd) }
    }

    /// The records directory as a verified descriptor: the base is opened
    /// by path, then each of `OpenApps`, `<app id>` and `records` with
    /// `openat(O_DIRECTORY | O_NOFOLLOW)`, so a symlink or a file in the
    /// chain is refused. nil when a component does not exist and `create`
    /// is false; with `create`, missing components are made at `0700` and
    /// each new entry is synced in its parent before going on.
    private func openDirectory(create: Bool) throws(LicenseStoreError) -> Descriptor? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current: Descriptor
        let base = system.open(baseDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if base >= 0 {
            current = Descriptor(base, system: system)
        } else if errno == ENOENT, !create {
            return nil
        } else if errno == ENOENT {
            do {
                try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            } catch {
                throw .unavailable("couldn’t create \(baseDirectory.lastPathComponent): \(error.localizedDescription)")
            }
            let again = system.open(baseDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard again >= 0 else { throw .unavailable(Self.describe("open", "the \(baseDirectory.lastPathComponent) directory")) }
            current = Descriptor(again, system: system)
        } else {
            throw .unavailable(Self.describe("open", "the \(baseDirectory.lastPathComponent) directory"))
        }

        for component in Self.relativeComponents(appID: appID) {
            var fd = system.openat(current.fd, component, flags, 0)
            if fd < 0, errno == ENOENT {
                guard create else { return nil }
                guard system.mkdirat(current.fd, component, 0o700) == 0 || errno == EEXIST else {
                    throw .unavailable(Self.describe("create", "the \(component) directory"))
                }
                // The new entry is on disk before anything is put inside it.
                guard system.fsync(current.fd) == 0 else { throw .unavailable(Self.describe("sync", "the new \(component) directory")) }
                fd = system.openat(current.fd, component, flags, 0)
            }
            guard fd >= 0 else {
                // ELOOP: a symlink; ENOTDIR: a file; anything else: can't open.
                throw .unavailable(Self.describe("open", "the \(component) directory"))
            }
            current = Descriptor(fd, system: system)
        }
        return current
    }

    /// nil only when there is positively no entry — no records directory,
    /// or no file of that name in it. A symlink (`ELOOP`), anything that is
    /// not a regular file, or any other failure to open or read is
    /// `.unavailable`. `O_NONBLOCK` keeps a FIFO left in the record's place
    /// from hanging the licensing executor; it is refused after `fstat`.
    private func readFile(_ file: String) throws(LicenseStoreError) -> Data? {
        guard let dir = try openDirectory(create: false) else { return nil }
        let fd = system.openat(dir.fd, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw .unavailable(Self.describe("open", "the \(file) record"))
        }
        let handle = Descriptor(fd, system: system)
        try requireRegularFile(handle, file)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(handle.fd, &buffer, buffer.count)
            if count == 0 { return bytes }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unavailable(Self.describe("read", "the \(file) record"))
            }
            bytes.append(buffer, count: count)
        }
    }

    private func requireRegularFile(_ handle: Descriptor, _ file: String) throws(LicenseStoreError) {
        var status = stat()
        guard fstat(handle.fd, &status) == 0 else { throw .unavailable(Self.describe("stat", "the \(file) record")) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw .unavailable("the \(file) record is not a regular file") }
    }

    /// Creates the directories (`0700`) if needed, writes a `0600` temporary
    /// file beside the record, `fsync`s it, renames it over the old file and
    /// `fsync`s the directory. Every step is checked. Before the rename a
    /// failure is `.unavailable`, leaves the old file untouched and removes
    /// the temporary one; the rename replaces only a regular file or nothing
    /// — a symlink or a special file in the record's place is refused. The
    /// directory descriptor is open before the rename, so after it nothing
    /// but its `fsync` can fail, and that is `.indeterminate`.
    private func writeFile(_ file: String, _ bytes: Data) throws(LicenseStoreError) {
        guard let dir = try openDirectory(create: true) else { throw .unavailable("couldn’t open the records directory") }
        let temporary = ".\(file).\(UUID().uuidString).tmp"
        let fd = system.openat(dir.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unavailable(Self.describe("create", "a temporary file for the \(file) record")) }
        let handle = Descriptor(fd, system: system)
        var renamed = false
        defer { if !renamed { _ = system.unlinkat(dir.fd, temporary, 0) } }

        guard system.fchmod(handle.fd, 0o600) == 0 else { throw .unavailable(Self.describe("chmod", "the \(file) record")) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                system.write(handle.fd, raw.baseAddress! + offset, bytes.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unavailable(Self.describe("write", "the \(file) record"))
            }
            offset += count
        }
        guard system.fsync(handle.fd) == 0 else { throw .unavailable(Self.describe("sync", "the \(file) record")) }

        // Only a regular file (or nothing) is replaced. The check and the
        // rename are two calls, so a link planted in between would still be
        // replaced by the new file rather than followed — rename never
        // follows — which is the harmless outcome.
        var existing = stat()
        if system.fstatat(dir.fd, file, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw .unavailable("the \(file) record is not a regular file") }
        } else if errno != ENOENT {
            throw .unavailable(Self.describe("stat", "the \(file) record"))
        }
        guard system.renameat(dir.fd, temporary, dir.fd, file) == 0 else { throw .unavailable(Self.describe("rename", "the \(file) record")) }
        renamed = true
        guard system.fsync(dir.fd) == 0 else { throw .indeterminate(Self.describe("sync", "the records directory after writing \(file)")) }
    }

    /// `unlink`, then `fsync` of the directory. No records directory or no
    /// such file is already deleted; a failed unlink is `.unavailable`, a
    /// failed sync after it `.indeterminate`. The entry is removed whatever
    /// it is — unlinking a link never touches what it points at.
    private func delete(file: String) throws(LicenseStoreError) {
        guard let dir = try openDirectory(create: false) else { return }
        guard system.unlinkat(dir.fd, file, 0) == 0 || errno == ENOENT else { throw .unavailable(Self.describe("delete", "the \(file) record")) }
        guard system.fsync(dir.fd) == 0 else { throw .indeterminate(Self.describe("sync", "the records directory after deleting \(file)")) }
    }

    private static func describe(_ operation: String, _ what: String) -> String {
        "couldn’t \(operation) \(what): \(String(cString: strerror(errno)))"
    }
}

/// The system calls the store mutates the disk with, so a test can make
/// any one of them fail. Each returns what the real call returns and leaves
/// `errno` set.
struct RecordFileSystem: Sendable {
    var open: @Sendable (_ path: String, _ flags: Int32) -> Int32
    var openat: @Sendable (_ dirfd: Int32, _ name: String, _ flags: Int32, _ mode: mode_t) -> Int32
    var close: @Sendable (_ fd: Int32) -> Int32
    var mkdirat: @Sendable (_ dirfd: Int32, _ name: String, _ mode: mode_t) -> Int32
    var fchmod: @Sendable (_ fd: Int32, _ mode: mode_t) -> Int32
    var write: @Sendable (_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int
    var fsync: @Sendable (_ fd: Int32) -> Int32
    var fstatat: @Sendable (_ dirfd: Int32, _ name: String, _ status: UnsafeMutablePointer<stat>, _ flags: Int32) -> Int32
    var renameat: @Sendable (_ fromDirfd: Int32, _ from: String, _ toDirfd: Int32, _ to: String) -> Int32
    var unlinkat: @Sendable (_ dirfd: Int32, _ name: String, _ flags: Int32) -> Int32

    static let live = RecordFileSystem(
        open: { path, flags in Darwin.open(path, flags) },
        openat: { dirfd, name, flags, mode in Darwin.openat(dirfd, name, flags, mode) },
        close: { fd in Darwin.close(fd) },
        mkdirat: { dirfd, name, mode in Darwin.mkdirat(dirfd, name, mode) },
        fchmod: { fd, mode in Darwin.fchmod(fd, mode) },
        write: { fd, bytes, count in Darwin.write(fd, bytes, count) },
        fsync: { fd in Darwin.fsync(fd) },
        fstatat: { dirfd, name, status, flags in Darwin.fstatat(dirfd, name, status, flags) },
        renameat: { from, fromName, to, toName in Darwin.renameat(from, fromName, to, toName) },
        unlinkat: { dirfd, name, flags in Darwin.unlinkat(dirfd, name, flags) }
    )
}
