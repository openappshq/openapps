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

/// The replacement that never deletes what it did not verify as its own.
///
/// - The destination is refused while it is a symbolic link, or exists but
///   is not a macPaper saver (a bundle whose `Info.plist` names our bundle
///   id and principal class). A foreign directory under the saver's name
///   is left exactly as it is, and the install is reported, not forced.
/// - The new bundle is copied to a sibling staging name first and verified
///   there; only then is the old one (verified ours) moved aside, the new
///   one moved in, and the old one removed. A failure at any step puts the
///   old bundle back; nothing is removed before the copy succeeded.
nonisolated struct SaverInstaller: ScreenSaverInstaller {
    static let name = "macPaper.saver"
    static let bundleIdentifier = "com.openappshq.macpaper.saver"
    static let principalClass = "MacPaperSaverView"

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
        case foreignDestination
        case copyFailed(String)
        case stagedBundleInvalid

        var errorDescription: String? {
            switch self {
            case .noSource: "This build carries no screen saver (the packaged app does)."
            case .destinationIsSymlink: "~/Library/Screen Savers/\(SaverInstaller.name) is a symbolic link; macPaper won’t replace it. Remove it yourself first."
            case .foreignDestination: "Something that isn’t macPaper’s saver is at ~/Library/Screen Savers/\(SaverInstaller.name); macPaper won’t remove it. Move it away first."
            case .copyFailed(let reason): "Couldn’t copy the saver: \(reason)"
            case .stagedBundleInvalid: "The copied saver didn’t verify; nothing was replaced."
            }
        }
    }

    var isAvailable: Bool { source != nil }

    var isInstalled: Bool { Self.isOurSaver(at: destination) }

    /// The destination is a real directory (no symlink) holding our
    /// `Info.plist` identity.
    static func isOurSaver(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return false }
        return plist["CFBundleIdentifier"] as? String == bundleIdentifier && plist["NSPrincipalClass"] as? String == principalClass
    }

    func install() throws {
        guard let source else { throw InstallError.noSource }
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // What is there now: nothing, ours, or something else.
        let existing = try? fileManager.attributesOfItem(atPath: destination.path)
        if existing?[.type] as? FileAttributeType == .typeSymbolicLink { throw InstallError.destinationIsSymlink }
        let hadOurs = existing != nil && Self.isOurSaver(at: destination)
        if existing != nil, !hadOurs { throw InstallError.foreignDestination }
        // Stage the new bundle beside the destination and verify it there.
        let staged = folder.appendingPathComponent(".\(Self.name).installing-\(UUID().uuidString)")
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
        // Old aside (verified ours), new in, old gone; on failure the old
        // one comes back and the staged copy goes.
        let aside = folder.appendingPathComponent(".\(Self.name).previous-\(UUID().uuidString)")
        if hadOurs {
            do {
                try fileManager.moveItem(at: destination, to: aside)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw InstallError.copyFailed(error.localizedDescription)
            }
        }
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            try? fileManager.removeItem(at: staged)
            if hadOurs { try? fileManager.moveItem(at: aside, to: destination) }
            throw InstallError.copyFailed(error.localizedDescription)
        }
        if hadOurs, Self.isOurSaver(at: aside) { try? fileManager.removeItem(at: aside) }
    }
}
