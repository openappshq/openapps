import Foundation

/// Where the notes live: the choice Settings → General and the setup
/// guide's files step offer (design/products/opennotes.md, "Storage").
/// Derived from the folder path, never stored on its own: the folder
/// preference is the one record, so a chosen folder that is one of the
/// two built-in paths reads as that choice and any other as "Other
/// folder".
nonisolated public enum StorageChoice: String, CaseIterable, Sendable {
    /// `~/Documents/OpenNotes`.
    case thisMac
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/OpenNotes`, the
    /// folder Finder shows as "OpenNotes" under iCloud Drive.
    case iCloudDrive
    /// Any folder the user picked.
    case other

    public var title: String {
        switch self {
        case .thisMac: "On this Mac"
        case .iCloudDrive: "iCloud Drive"
        case .other: "Other folder…"
        }
    }
}

/// iCloud Drive as a folder: the app talks to it only through the file
/// system (no CloudKit, no ubiquity container, no entitlement — the app
/// ships self-signed). What the file system shows of iCloud's state is a
/// `.icloud` placeholder for a file not downloaded, a file replaced by
/// rename when a change arrives, and `NSFileVersion` conflict versions
/// when two Macs wrote the same file.
nonisolated public enum ICloudDrive {
    /// The folder Finder shows as "OpenNotes" under iCloud Drive.
    public static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        cloudDocs(home: home).appendingPathComponent("OpenNotes", isDirectory: true)
    }

    /// iCloud Drive's own root, present once the user is signed in with
    /// iCloud Drive on.
    public static func cloudDocs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Whether iCloud Drive can be chosen: its root exists. The ubiquity
    /// container (`url(forUbiquityContainerIdentifier:)`) is nil for an
    /// app without the container entitlement, so the folder is the test.
    public static func isAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: cloudDocs(home: home).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether a folder is under iCloud Drive's root (the chosen iCloud
    /// folder, or any folder the user picked inside it).
    public static func contains(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let root = cloudDocs(home: home).standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// What Settings says when iCloud Drive cannot be chosen.
    public static let unavailableNotice = "Sign in to iCloud Drive in System Settings to keep notes there."

    // MARK: - Placeholders

    /// iCloud's stand-in for a file it has not downloaded:
    /// `.<name>.md.icloud`, hidden, beside where the file will be.
    public static func placeholderName(for id: NoteID) -> String {
        "." + id.fileName + ".icloud"
    }

    /// The note a placeholder file name stands for, or nil for any other name.
    public static func note(forPlaceholderName name: String) -> NoteID? {
        guard name.hasPrefix("."), name.hasSuffix(".md.icloud") else { return nil }
        let stem = name.dropFirst().dropLast(".md.icloud".count)
        guard !stem.isEmpty else { return nil }
        return NoteID(String(stem))
    }
}

/// What iCloud's file-level API is asked, behind a seam so the store can
/// be tested against a temporary folder that iCloud never sees.
public protocol Ubiquity: AnyObject {
    /// Whether the folder is iCloud's (`isUbiquitousItem`, true without
    /// any entitlement for iCloud Drive and for Desktop & Documents kept
    /// in iCloud).
    func isUbiquitous(_ url: URL) -> Bool
    /// Asks iCloud to download the file behind a placeholder. Nothing
    /// happens for a file that is not iCloud's; an error is reported, not
    /// thrown past the store.
    func startDownloading(_ url: URL) throws
    /// The versions of the file iCloud could not merge (another Mac wrote
    /// it at the same time), still unresolved. Empty for a file that is
    /// not iCloud's.
    func unresolvedConflictVersions(of url: URL) -> [any UbiquityConflictVersion]
}

/// One unresolved version of a file: what it holds and where it came
/// from. Marked resolved once the store has kept it under a visible name.
public protocol UbiquityConflictVersion: AnyObject {
    /// The version's bytes, read coordinated.
    func contents() throws -> Data
    /// The Mac that wrote it, when iCloud knows.
    var device: String? { get }
    var modified: Date? { get }
    /// The version is kept elsewhere now; iCloud may drop it.
    func markResolved()
}

/// `FileManager` and `NSFileVersion`: the real thing. Both are called on
/// plain paths under iCloud Drive from an unsandboxed, self-signed app
/// with no container entitlement; `isUbiquitousItem` is known to answer
/// there, the download request and the version query are expected to and
/// their refusals are surfaced, never assumed away.
public final class FileManagerUbiquity: Ubiquity {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func isUbiquitous(_ url: URL) -> Bool {
        fileManager.isUbiquitousItem(at: url)
    }

    public func startDownloading(_ url: URL) throws {
        try fileManager.startDownloadingUbiquitousItem(at: url)
    }

    public func unresolvedConflictVersions(of url: URL) -> [any UbiquityConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map(FileVersion.init)
    }

    private final class FileVersion: UbiquityConflictVersion {
        private let version: NSFileVersion

        init(_ version: NSFileVersion) {
            self.version = version
        }

        func contents() throws -> Data {
            var coordinationError: NSError?
            var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: version.url, options: [], error: &coordinationError) { url in
                result = Result { try Data(contentsOf: url) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }

        var device: String? { version.localizedNameOfSavingComputer }
        var modified: Date? { version.modificationDate }

        func markResolved() {
            version.isResolved = true
        }
    }
}

/// What the footer says about iCloud Drive while it is the folder in use
/// (design/products/opennotes.md, "Storage").
nonisolated public enum StorageStatus: Hashable, Sendable {
    /// Every note's file is on this Mac and nothing is held. Only what the
    /// file system shows: whether iCloud has finished uploading is not
    /// observed, so nothing is claimed about the other Macs.
    case allOnThisMac
    /// Files iCloud has not downloaded; `requested` of them were asked for
    /// (a note opened).
    case notDownloaded(count: Int, requested: Int)
    /// A write is held until iCloud brings a file back (a note evicted
    /// while it had unsaved text).
    case waiting
    /// Conflict versions iCloud kept that wait for a license to be written
    /// out as conflict copies.
    case conflictsWaiting(Int)

    public var text: String {
        switch self {
        case .allOnThisMac: "all notes on this Mac"
        case .notDownloaded(let count, let requested):
            requested > 0 ? "downloading \(requested) of \(count)" : "\(count) not downloaded"
        case .waiting: "waiting for iCloud"
        case .conflictsWaiting(let count): "\(count) conflict \(count == 1 ? "version waits" : "versions wait") for a license"
        }
    }
}
