import Darwin
import Foundation

/// Replacing the installed bundle with a staged one that sits next to it,
/// in one atomic exchange (`renamex_np(RENAME_SWAP)`): at no instant is the
/// app missing, and the old bundle — which lands in the staging folder — is
/// deleted only once the exchange is known to have succeeded. A volume
/// without atomic exchanges cannot be updated in place; the install is
/// refused and nothing changes.
///
/// A state file next to the staging folder records the transaction before
/// any mutation, so recovery at the next launch knows what the folder
/// holds: a download that was never installed (`staging`), the old bundle
/// after a completed exchange (`superseded`), or something ambiguous
/// (`exchanging`, missing, unreadable), which is preserved and reported,
/// never deleted on the updater's own authority.
public enum UpdateSwap {
    /// The operations of a swap, in order, for failure injection in tests.
    public enum Step: Equatable, Sendable {
        /// Writing the `exchanging` state, before any mutation.
        case mark
        /// The atomic exchange.
        case exchange
        /// Writing the `superseded` state, after the exchange.
        case markSuperseded
    }

    /// What the staging folder holds, as recorded before each step.
    public enum State: String, Sendable {
        /// A download being unpacked, or a staged update not yet installed. Safe to discard.
        case staging
        /// The exchange is about to run or has run without its completion being recorded. Ambiguous: preserved.
        case exchanging
        /// The exchange completed; the folder holds the old bundle. Safe to discard.
        case superseded
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The staging folder holds a preserved bundle from an earlier
        /// interrupted or failed swap; nothing is staged or swapped over it.
        case backupPreserved(URL)
        /// The transaction state could not be recorded; nothing was changed.
        case cannotRecordState(String)
        /// The volume has no atomic exchange; nothing was changed.
        case atomicExchangeUnsupported
        /// The exchange failed; nothing was changed.
        case exchange(String)

        public var errorDescription: String? {
            switch self {
            case .backupPreserved(let backup): "A previous copy from an interrupted update is kept at \(backup.path); remove it before updating again."
            case .cannotRecordState(let error): "Could not record the update's state next to the app: \(error). Nothing was changed."
            case .atomicExchangeUnsupported: "This disk can't exchange the app in place. Move the app to the Applications folder on your startup disk to enable updates."
            case .exchange(let error): "Could not exchange the apps: \(error). Nothing was changed."
            }
        }
    }

    /// What `recover` found at launch.
    public enum Recovery: Equatable, Sendable {
        case nothing
        /// A completed exchange's old bundle, or an uninstalled download, was cleaned up.
        case cleaned
        /// The staging folder holds a bundle of uncertain provenance; it was left alone.
        case backupPreserved(URL)
    }

    /// Where a downloaded bundle is unpacked: next to the app, so the swap is
    /// a rename on the same volume. Created mode 0700.
    public static func stagingDirectory(for app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("." + app.lastPathComponent + ".update", isDirectory: true)
    }

    /// The transaction state for the staging folder.
    public static func stateLocation(for app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("." + app.lastPathComponent + ".update.state", isDirectory: false)
    }

    public static func state(for app: URL, fileManager: FileManager = .default) -> State? {
        guard let data = fileManager.contents(atPath: stateLocation(for: app).path) else { return nil }
        return State(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Records the state durably; a failure means nothing further may happen.
    static func record(_ state: State, for app: URL, fileManager: FileManager = .default) throws {
        let url = stateLocation(for: app)
        do {
            try Data(state.rawValue.utf8).write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Read back: the state is what recovery relies on.
            guard Self.state(for: app, fileManager: fileManager) == state else { throw Failure.cannotRecordState("read back a different state") }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cannotRecordState(error.localizedDescription)
        }
    }

    /// Whether the staging folder holds a bundle whose provenance is not
    /// recorded as safe to discard.
    public static func preservedBackup(for app: URL, fileManager: FileManager = .default) -> URL? {
        let staging = stagingDirectory(for: app)
        guard let bundle = bundle(in: staging, named: app.lastPathComponent, fileManager: fileManager) else { return nil }
        switch state(for: app, fileManager: fileManager) {
        case .staging, .superseded: return nil
        case .exchanging, nil: return bundle
        }
    }

    private static func bundle(in directory: URL, named name: String, fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        let candidates = [directory.appendingPathComponent(name, isDirectory: true), directory.appendingPathComponent("unpacked/\(name)", isDirectory: true)]
        return candidates.first { fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
    }

    /// Creates the staging directory, empty and private to this user, and
    /// records the `staging` state first. Refuses while a preserved bundle
    /// sits there.
    public static func prepareStagingDirectory(for app: URL, fileManager: FileManager = .default) throws -> URL {
        if let preserved = preservedBackup(for: app, fileManager: fileManager) { throw Failure.backupPreserved(preserved) }
        let staging = stagingDirectory(for: app)
        try? fileManager.removeItem(at: staging)
        try record(.staging, for: app, fileManager: fileManager)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return staging
    }

    /// Exchanges `app` and `staged` (both on the same volume, `staged` inside
    /// the staging folder) atomically. `before` runs ahead of each step and
    /// may fail it. On success the staging folder, now holding the old
    /// bundle, is removed; on any failure before the exchange nothing has
    /// changed. Refuses without an atomic exchange and over a preserved bundle.
    public static func swap(app: URL, staged: URL, fileManager: FileManager = .default, before: (Step) throws -> Void = { _ in }) throws {
        if let preserved = preservedBackup(for: app, fileManager: fileManager) { throw Failure.backupPreserved(preserved) }
        for url in [app, staged, stagingDirectory(for: app)] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw Failure.exchange("\(url.lastPathComponent) is a symbolic link")
            }
        }
        // The state goes first: from here on, recovery knows the folder may hold either bundle.
        do { try before(.mark) } catch { throw Failure.cannotRecordState(error.localizedDescription) }
        try record(.exchanging, for: app, fileManager: fileManager)
        do {
            try before(.exchange)
        } catch {
            // Refused before the syscall: the folder still holds the download.
            try? record(.staging, for: app, fileManager: fileManager)
            throw Failure.exchange(error.localizedDescription)
        }
        if renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) != 0 {
            let code = errno
            // Nothing changed: the folder still holds the download.
            try? record(.staging, for: app, fileManager: fileManager)
            if code == ENOTSUP || code == EINVAL || code == EXDEV { throw Failure.atomicExchangeUnsupported }
            throw Failure.exchange(String(cString: strerror(code)))
        }
        // The new app is in place. Only a recorded `superseded` lets the old bundle go.
        do {
            try before(.markSuperseded)
            try record(.superseded, for: app, fileManager: fileManager)
        } catch {
            // The exchange stands; the old bundle stays preserved until recovery or the user resolves it.
            return
        }
        finish(app: app, fileManager: fileManager)
    }

    private static func finish(app: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: stagingDirectory(for: app))
        try? fileManager.removeItem(at: stateLocation(for: app))
        // Launch Services notices a changed bundle by its modification date.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
    }

    /// Cleans up after an interrupted or finished swap, safe to call at every
    /// launch. Only a folder whose recorded state says it holds a never-
    /// installed download or an already-superseded old bundle is removed;
    /// anything else with a bundle in it is preserved and reported.
    @discardableResult
    public static func recover(app: URL, fileManager: FileManager = .default) -> Recovery {
        let staging = stagingDirectory(for: app)
        let state = stateLocation(for: app)
        guard fileManager.fileExists(atPath: staging.path) else {
            try? fileManager.removeItem(at: state)
            return .nothing
        }
        if let preserved = preservedBackup(for: app, fileManager: fileManager) {
            return .backupPreserved(preserved)
        }
        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: state)
        return .cleaned
    }

    /// Removes a preserved bundle once the user has decided the installed
    /// app works. The state is cleared only after the folder is gone.
    public static func discardPreservedBackup(for app: URL, fileManager: FileManager = .default) throws {
        let staging = stagingDirectory(for: app)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try? fileManager.removeItem(at: stateLocation(for: app))
    }
}
