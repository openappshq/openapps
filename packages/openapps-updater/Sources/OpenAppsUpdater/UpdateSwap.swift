import Darwin
import Foundation

/// Replacing the installed bundle with a staged one that sits next to it.
/// On APFS the two paths are exchanged in one atomic rename
/// (`renamex_np(RENAME_SWAP)`): at no instant is the app missing, and
/// nothing is deleted until the new bundle is in place. On a volume without
/// atomic swaps the fallback moves the old bundle aside and the new one in;
/// a marker written first makes an interrupted fallback recoverable at the
/// next launch, and any failure puts the old bundle back — or, if even that
/// fails, keeps it as a preserved backup that nothing deletes on its own.
public enum UpdateSwap {
    /// The operations of a swap, in order, for failure injection in tests.
    public enum Step: Equatable, Sendable {
        /// The atomic exchange.
        case exchange
        /// Fallback: moving the old bundle aside.
        case moveAside
        /// Fallback: moving the new bundle in.
        case moveIn
    }

    /// How a successful swap was done.
    public enum Outcome: Equatable, Sendable {
        /// One atomic exchange.
        case exchanged
        /// The fallback: moved aside, then moved in.
        case moved
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// A preserved backup from an earlier failed swap is still in place;
        /// nothing is swapped over it.
        case backupPreserved(URL)
        case clearPrevious(String)
        /// The exchange failed; nothing changed.
        case exchange(String)
        /// Fallback: the old bundle could not be moved aside; nothing changed.
        case moveAside(String)
        /// Fallback: the new bundle could not be moved in; the old one was rolled back into place.
        case rolledBack(String)
        /// Fallback: the new bundle could not be moved in and the old one
        /// could not be put back either. It is preserved at `backup`, with a
        /// marker, until someone removes it deliberately.
        case rollbackFailed(moveIn: String, restore: String, backup: URL)

        public var errorDescription: String? {
            switch self {
            case .backupPreserved(let backup): "A previous copy from a failed update is still at \(backup.path); remove it before updating again."
            case .clearPrevious(let error): "Could not clear the previous copy: \(error)"
            case .exchange(let error): "Could not exchange the apps: \(error)"
            case .moveAside(let error): "Could not move the current app aside: \(error)"
            case .rolledBack(let error): "Could not move the new app into place: \(error). The current version was put back."
            case .rollbackFailed(let moveIn, let restore, let backup):
                "Could not move the new app into place (\(moveIn)), and the current version could not be put back (\(restore)); it is kept at \(backup.path)"
            }
        }
    }

    /// What `recover` found at launch.
    public enum Recovery: Equatable, Sendable {
        case nothing
        /// The app had been moved aside and never replaced; it is back.
        case restored
        /// A backup from a failed swap is preserved at this path; it was left alone.
        case backupPreserved(URL)
    }

    /// Where a downloaded bundle is unpacked: next to the app, so the swap is
    /// a rename on the same volume. Created mode 0700.
    public static func stagingDirectory(for app: URL) -> URL {
        sibling(of: app, suffix: ".update")
    }

    /// Where the running bundle waits during a fallback swap, and stays as
    /// the preserved backup if the swap fails both ways.
    public static func previousLocation(for app: URL) -> URL {
        sibling(of: app, suffix: ".previous")
    }

    /// Present while a fallback swap is in flight.
    public static func markerLocation(for app: URL) -> URL {
        sibling(of: app, suffix: ".swapping")
    }

    /// Present while `previousLocation` holds a preserved backup.
    public static func backupMarkerLocation(for app: URL) -> URL {
        sibling(of: app, suffix: ".backup")
    }

    private static func sibling(of app: URL, suffix: String) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("." + app.lastPathComponent + suffix, isDirectory: true)
    }

    /// Creates the staging directory, empty and private to this user.
    public static func prepareStagingDirectory(for app: URL, fileManager: FileManager = .default) throws -> URL {
        let staging = stagingDirectory(for: app)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return staging
    }

    /// Whether a backup from a failed swap is preserved next to `app`.
    public static func preservedBackup(for app: URL, fileManager: FileManager = .default) -> URL? {
        let previous = previousLocation(for: app)
        guard fileManager.fileExists(atPath: backupMarkerLocation(for: app).path), fileManager.fileExists(atPath: previous.path) else { return nil }
        return previous
    }

    /// Replaces `app` with `staged`, which must be on the same volume. `before`
    /// runs ahead of each operation and may fail it. `atomic` forces or
    /// forbids the atomic exchange (nil: try it, fall back when the volume
    /// cannot). On success the old bundle is gone and the staging folder
    /// removed; on any failure the old bundle is in place, or preserved and
    /// the error says where.
    @discardableResult
    public static func swap(app: URL, staged: URL, fileManager: FileManager = .default, atomic: Bool? = nil,
                            before: (Step) throws -> Void = { _ in }) throws -> Outcome {
        if let backup = preservedBackup(for: app, fileManager: fileManager) { throw Failure.backupPreserved(backup) }
        if atomic != false {
            do { try before(.exchange) } catch { throw Failure.exchange(error.localizedDescription) }
            if renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 {
                finish(app: app, fileManager: fileManager)
                return .exchanged
            }
            let code = errno
            if atomic == true || !(code == ENOTSUP || code == EINVAL || code == EXDEV) {
                throw Failure.exchange(String(cString: strerror(code)))
            }
        }
        try fallbackSwap(app: app, staged: staged, fileManager: fileManager, before: before)
        return .moved
    }

    private static func fallbackSwap(app: URL, staged: URL, fileManager: FileManager, before: (Step) throws -> Void) throws {
        let previous = previousLocation(for: app)
        let marker = markerLocation(for: app)
        if fileManager.fileExists(atPath: previous.path) {
            do { try fileManager.removeItem(at: previous) } catch { throw Failure.clearPrevious(error.localizedDescription) }
        }
        // The marker outlives a crash between the two moves, so recovery
        // knows a swap was in flight even if the app itself is missing.
        fileManager.createFile(atPath: marker.path, contents: Data(staged.path.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? fileManager.removeItem(at: marker) }
        do {
            try before(.moveAside)
            try fileManager.moveItem(at: app, to: previous)
        } catch {
            throw Failure.moveAside(error.localizedDescription)
        }
        do {
            try before(.moveIn)
            try fileManager.moveItem(at: staged, to: app)
        } catch {
            do {
                try fileManager.moveItem(at: previous, to: app)
            } catch let restore {
                // The old bundle stays where it is, marked, and nothing here or in `recover` deletes it.
                fileManager.createFile(atPath: backupMarkerLocation(for: app).path,
                                       contents: Data("\(restore.localizedDescription)\n".utf8), attributes: [.posixPermissions: 0o600])
                throw Failure.rollbackFailed(moveIn: error.localizedDescription, restore: restore.localizedDescription, backup: previous)
            }
            throw Failure.rolledBack(error.localizedDescription)
        }
        try? fileManager.removeItem(at: previous)
        finish(app: app, fileManager: fileManager)
    }

    private static func finish(app: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: stagingDirectory(for: app))
        // Launch Services notices a changed bundle by its modification date.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
    }

    /// Cleans up after an interrupted or finished swap, safe to call at every
    /// launch: an app that was moved aside but never replaced comes back; a
    /// leftover previous copy, marker or staging folder goes away — except a
    /// preserved backup, which is reported and left alone.
    @discardableResult
    public static func recover(app: URL, fileManager: FileManager = .default) -> Recovery {
        let previous = previousLocation(for: app)
        var result = Recovery.nothing
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: previous.path, isDirectory: &isDirectory), isDirectory.boolValue {
            if !fileManager.fileExists(atPath: app.path) {
                // Whatever the marker says, an app that is missing comes back.
                if (try? fileManager.moveItem(at: previous, to: app)) != nil {
                    try? fileManager.removeItem(at: backupMarkerLocation(for: app))
                    result = .restored
                }
            } else if fileManager.fileExists(atPath: backupMarkerLocation(for: app).path) {
                result = .backupPreserved(previous)
            } else {
                try? fileManager.removeItem(at: previous)
            }
        } else {
            try? fileManager.removeItem(at: backupMarkerLocation(for: app))
        }
        try? fileManager.removeItem(at: markerLocation(for: app))
        try? fileManager.removeItem(at: stagingDirectory(for: app))
        return result
    }

    /// Removes a preserved backup once the user has decided the installed
    /// app works.
    public static func discardPreservedBackup(for app: URL, fileManager: FileManager = .default) throws {
        try? fileManager.removeItem(at: backupMarkerLocation(for: app))
        let previous = previousLocation(for: app)
        if fileManager.fileExists(atPath: previous.path) {
            try fileManager.removeItem(at: previous)
        }
    }
}
