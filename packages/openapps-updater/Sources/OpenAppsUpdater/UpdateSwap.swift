import Darwin
import Foundation

/// Replacing the installed bundle with a staged one that sits next to it.
/// On APFS the two paths are exchanged in one atomic rename
/// (`renamex_np(RENAME_SWAP)`): at no instant is the app missing, and
/// nothing is deleted until the new bundle is in place. On a volume without
/// atomic swaps the fallback moves the old bundle aside and the new one in;
/// a marker written first makes an interrupted fallback recoverable at the
/// next launch, and any failure puts the old bundle back or says where it is.
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

    public enum Failure: Error, Equatable, LocalizedError {
        case clearPrevious(String)
        case exchange(String)
        case moveAside(String)
        /// The new app could not be moved in; the old one is back in place.
        case moveIn(String)
        /// The new app could not be moved in and the old one could not be put
        /// back either; it is still at `previous`.
        case restore(moveIn: String, restore: String, previous: URL)

        public var errorDescription: String? {
            switch self {
            case .clearPrevious(let error): "Could not clear the previous copy: \(error)"
            case .exchange(let error): "Could not exchange the apps: \(error)"
            case .moveAside(let error): "Could not move the current app aside: \(error)"
            case .moveIn(let error): "Could not move the new app into place: \(error)"
            case .restore(let moveIn, let restore, let previous):
                "Could not move the new app into place (\(moveIn)), and the previous copy could not be put back (\(restore)); it is at \(previous.path)"
            }
        }
    }

    /// Where a downloaded bundle is unpacked: next to the app, so the swap is
    /// a rename on the same volume. Created mode 0700.
    public static func stagingDirectory(for app: URL) -> URL {
        sibling(of: app, suffix: ".update")
    }

    /// Where the running bundle waits during a fallback swap.
    public static func previousLocation(for app: URL) -> URL {
        sibling(of: app, suffix: ".previous")
    }

    /// Present while a fallback swap is in flight.
    public static func markerLocation(for app: URL) -> URL {
        sibling(of: app, suffix: ".swapping")
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

    /// Replaces `app` with `staged`, which must be on the same volume. `before`
    /// runs ahead of each operation and may fail it. `atomic` forces or
    /// forbids the atomic exchange (nil: try it, fall back when the volume
    /// cannot). On success the old bundle is gone and the staging folder
    /// removed; on any failure the old bundle is in place, or the error says
    /// where it is.
    public static func swap(app: URL, staged: URL, fileManager: FileManager = .default, atomic: Bool? = nil,
                            before: (Step) throws -> Void = { _ in }) throws {
        if atomic != false {
            do { try before(.exchange) } catch { throw Failure.exchange(error.localizedDescription) }
            if renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 {
                finish(app: app, fileManager: fileManager)
                return
            }
            let code = errno
            if atomic == true || !(code == ENOTSUP || code == EINVAL || code == EXDEV) {
                throw Failure.exchange(String(cString: strerror(code)))
            }
        }
        try fallbackSwap(app: app, staged: staged, fileManager: fileManager, before: before)
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
                throw Failure.restore(moveIn: error.localizedDescription, restore: restore.localizedDescription, previous: previous)
            }
            throw Failure.moveIn(error.localizedDescription)
        }
        try? fileManager.removeItem(at: previous)
        finish(app: app, fileManager: fileManager)
    }

    private static func finish(app: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: stagingDirectory(for: app))
        // Launch Services notices a changed bundle by its modification date.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
    }

    /// Cleans up after an interrupted or finished swap: an app that was moved
    /// aside but never replaced comes back, a leftover previous copy, marker
    /// or staging folder goes away. Safe to call at every launch.
    public static func recover(app: URL, fileManager: FileManager = .default) {
        let previous = previousLocation(for: app)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: previous.path, isDirectory: &isDirectory), isDirectory.boolValue {
            if fileManager.fileExists(atPath: app.path) {
                try? fileManager.removeItem(at: previous)
            } else {
                try? fileManager.moveItem(at: previous, to: app)
            }
        }
        try? fileManager.removeItem(at: markerLocation(for: app))
        try? fileManager.removeItem(at: stagingDirectory(for: app))
    }
}
