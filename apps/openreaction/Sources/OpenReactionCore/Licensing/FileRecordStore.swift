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
/// Reads report what they found: no file is *absent* (nil); a directory or
/// file that cannot be read is `.unavailable`; a wrong magic, a failed tag
/// or undecodable JSON is `.corrupt`. Both errors are storage errors to the
/// manager — no new trial, no registry call, nothing overwritten. Writes go
/// to a temporary file in the same directory, are `fsync`ed and renamed
/// over the old file, so a failed save leaves the old record intact.
public struct FileRecordStore: LicenseStore, TrialStore, Sendable {
    /// The format tag every file starts with.
    public static let magic = "openapps-records-v1"
    public static let licenseFile = "license"
    public static let trialFile = "trial"
    public static let cleanupsFile = "cleanups"
    /// Stands in for the hardware UUID in the key when it cannot be read.
    public static let noHardwareUUID = "no-hardware-uuid"

    /// `.../OpenApps/<app id>/records`.
    public let directory: URL
    private let appID: String
    /// The derived key's bytes; a `SymmetricKey` is built per operation.
    private let keyData: Data

    /// - Parameters:
    ///   - appID: Salts the key and the authenticated data (`openreaction`).
    ///   - device: The hardware UUID the key derives from, read once here.
    ///   - directory: The records directory; the default is the user's
    ///     Application Support. Tests pass a temporary one.
    public init(appID: String, device: any DeviceIdentity, directory: URL? = nil) {
        self.appID = appID
        self.directory = directory ?? Self.defaultDirectory(appID: appID)
        keyData = Self.deriveKey(appID: appID, hardwareUUID: device.hardwareUUID())
    }

    /// `~/Library/Application Support/OpenApps/<app id>/records`.
    public static func defaultDirectory(appID: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("OpenApps", isDirectory: true)
            .appendingPathComponent(appID, isDirectory: true)
            .appendingPathComponent("records", isDirectory: true)
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

    private func path(_ file: String) -> String {
        directory.appendingPathComponent(file, isDirectory: false).path
    }

    /// nil only when the file positively does not exist (`ENOENT`, which
    /// covers a missing directory too). Any other failure to open or read
    /// is `.unavailable`.
    private func readFile(_ file: String) throws(LicenseStoreError) -> Data? {
        let fd = Darwin.open(path(file), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw .unavailable(Self.describe("open", file))
        }
        defer { close(fd) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return bytes }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unavailable(Self.describe("read", file))
            }
            bytes.append(buffer, count: count)
        }
    }

    /// Creates the directory (`0700`) if needed, writes a `0600` temporary
    /// file beside the record, `fsync`s it and renames it over the old file.
    /// Whatever fails, the old file is left as it was and the temporary one
    /// is removed.
    private func writeFile(_ file: String, _ bytes: Data) throws(LicenseStoreError) {
        try ensureDirectory()
        let temporary = path(".\(file).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unavailable(Self.describe("create", file)) }
        var written = false
        defer {
            close(fd)
            if !written { unlink(temporary) }
        }
        guard fchmod(fd, 0o600) == 0 else { throw .unavailable(Self.describe("chmod", file)) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, bytes.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unavailable(Self.describe("write", file))
            }
            offset += count
        }
        guard fsync(fd) == 0 else { throw .unavailable(Self.describe("fsync", file)) }
        guard rename(temporary, path(file)) == 0 else { throw .unavailable(Self.describe("rename", file)) }
        written = true
        // Best effort: the directory entry itself reaches the disk too.
        let dir = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 {
            fsync(dir)
            close(dir)
        }
    }

    /// A missing file is already deleted; anything else is `.unavailable`.
    private func delete(file: String) throws(LicenseStoreError) {
        guard unlink(path(file)) == 0 || errno == ENOENT else { throw .unavailable(Self.describe("delete", file)) }
    }

    /// Creates the records directory (and the `OpenApps/<app id>` above it)
    /// at `0700` when it is missing; an existing one is used as it is.
    private func ensureDirectory() throws(LicenseStoreError) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw .unavailable("\(directory.lastPathComponent) is not a directory") }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .unavailable("couldn’t create the records directory: \(error.localizedDescription)")
        }
    }

    private static func describe(_ operation: String, _ file: String) -> String {
        "couldn’t \(operation) the \(file) record: \(String(cString: strerror(errno)))"
    }
}
