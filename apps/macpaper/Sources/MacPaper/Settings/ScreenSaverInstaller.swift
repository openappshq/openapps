import Darwin
import Foundation

/// Installs `macPaper.saver` for the user. The app's copies the bundle
/// shipped in its Resources into `~/Library/Screen Savers/`; the preview
/// harness installs nothing.
nonisolated protocol ScreenSaverInstaller {
    /// Whether the app carries the saver at all (a `swift build` does not).
    var isAvailable: Bool { get }
    /// Whether macPaper's own saver is at the destination.
    var isInstalled: Bool { get }
    func install() throws
}

/// The replacement that never deletes what it did not verify as its own,
/// and never leaves the destination missing.
///
/// - The destination is refused while it is a symbolic link, or exists but
///   is not a macPaper saver (a bundle whose `Info.plist` names our bundle
///   id and principal class). A foreign directory under the saver's name
///   is left exactly as it is, and the install is reported, not forced.
///   `~/Library/Screen Savers` itself is refused while it is a symbolic
///   link: nothing is written through a redirected folder.
/// - The new bundle is copied to a sibling staging name first and verified
///   there. An old bundle (verified ours) is then exchanged with it in one
///   atomic `renamex_np(RENAME_SWAP)`, the way the updater swaps the app:
///   at no instant is the saver missing, and a volume without atomic
///   exchanges is refused with nothing changed. With no old bundle a single
///   rename puts the new one in place.
/// - After the exchange the staging name holds the old bundle, which is
///   removed. An interruption there leaves only a leftover under the
///   staging prefix; the next install (and `isInstalled`) removes every
///   leftover that verifies as ours, and leaves anything else alone.
nonisolated struct SaverInstaller: ScreenSaverInstaller {
    static let name = "macPaper.saver"
    static let bundleIdentifier = "com.openappshq.macpaper.saver"
    static let principalClass = "MacPaperSaverView"
    /// Staging names beside the destination: `.macPaper.saver.installing-<uuid>`.
    static let stagingPrefix = ".\(name).installing-"

    /// The bundle shipped in the app, nil in a `swift build`.
    let source: URL?
    /// `~/Library/Screen Savers/macPaper.saver` unless a test says otherwise.
    let destination: URL

    init(source: URL? = Bundle.main.url(forResource: "macPaper", withExtension: "saver"), destination: URL? = nil) {
        self.source = source
        self.destination = destination ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/\(Self.name)")
    }

    enum InstallError: Error, LocalizedError, Equatable {
        case noSource
        case destinationIsSymlink
        case folderIsSymlink
        case foreignDestination
        case copyFailed(String)
        case stagedBundleInvalid
        case atomicExchangeUnsupported

        var errorDescription: String? {
            switch self {
            case .noSource: "This build carries no screen saver (the packaged app does)."
            case .destinationIsSymlink: "~/Library/Screen Savers/\(SaverInstaller.name) is a symbolic link; macPaper won’t replace it. Remove it yourself first."
            case .folderIsSymlink: "~/Library/Screen Savers is a symbolic link; macPaper won’t install through it."
            case .foreignDestination: "Something that isn’t macPaper’s saver is at ~/Library/Screen Savers/\(SaverInstaller.name); macPaper won’t remove it. Move it away first."
            case .copyFailed(let reason): "Couldn’t copy the saver: \(reason)"
            case .stagedBundleInvalid: "The copied saver didn’t verify; nothing was replaced."
            case .atomicExchangeUnsupported: "~/Library/Screen Savers is on a volume that can’t exchange the saver in one step; nothing was replaced."
            }
        }
    }

    var isAvailable: Bool { source != nil }

    var isInstalled: Bool {
        removeLeftovers()
        return Self.isOurSaver(at: destination)
    }

    /// The destination is a real directory (no symlink) holding our
    /// `Info.plist` identity.
    static func isOurSaver(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return false }
        return plist["CFBundleIdentifier"] as? String == bundleIdentifier && plist["NSPrincipalClass"] as? String == principalClass
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Staging leftovers of an interrupted install that verify as ours (a
    /// copy that never got exchanged, or the old bundle after the exchange):
    /// removed. Anything else under the prefix is left alone.
    func removeLeftovers() {
        let folder = destination.deletingLastPathComponent()
        guard !Self.isSymlink(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            let url = folder.appendingPathComponent(name)
            guard !Self.isSymlink(url), Self.isOurSaver(at: url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func install() throws {
        guard let source else { throw InstallError.noSource }
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        if Self.isSymlink(folder) { throw InstallError.folderIsSymlink }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        removeLeftovers()
        // What is there now: nothing, ours, or something else.
        let existing = try? fileManager.attributesOfItem(atPath: destination.path)
        if existing?[.type] as? FileAttributeType == .typeSymbolicLink { throw InstallError.destinationIsSymlink }
        let hadOurs = existing != nil && Self.isOurSaver(at: destination)
        if existing != nil, !hadOurs { throw InstallError.foreignDestination }
        // Stage the new bundle beside the destination and verify it there.
        let staged = folder.appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
        do {
            try fileManager.copyItem(at: source, to: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw InstallError.copyFailed(error.localizedDescription)
        }
        guard Self.isOurSaver(at: staged) else {
            try? fileManager.removeItem(at: staged)
            throw InstallError.stagedBundleInvalid
        }
        if hadOurs {
            // One exchange: the destination never goes missing. Afterwards
            // the staging name holds the old bundle.
            if renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) != 0 {
                let code = errno
                try? fileManager.removeItem(at: staged)
                if code == ENOTSUP || code == EINVAL || code == EXDEV { throw InstallError.atomicExchangeUnsupported }
                throw InstallError.copyFailed(String(cString: strerror(code)))
            }
            if Self.isOurSaver(at: staged) { try? fileManager.removeItem(at: staged) }
        } else {
            do {
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw InstallError.copyFailed(error.localizedDescription)
            }
        }
    }
}
