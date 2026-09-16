import Foundation
import Testing

/// A throwaway `UserDefaults` suite for one test, kept in a temporary
/// directory and gone again when the test is done.
///
/// A suite named like an app id lives in `~/Library/Preferences`, and
/// removing it there does not work: `removePersistentDomain(forName:)`
/// leaves cfprefsd holding an emptied domain that it writes back out as an
/// empty `<suite>.plist` — some time later, so deleting the file is undone
/// too. That is how test runs used to leave one file per test behind. A
/// suite named by an absolute path is kept at that path instead (the form
/// `defaults(1)` documents as "a path to an arbitrary plist file"), so the
/// suite lives under the temporary directory and `remove()` — or the last
/// reference going away — clears it and deletes the directory. Nothing is
/// ever written to `~/Library/Preferences`.
///
/// The same file lives in every package whose tests need a suite
/// (openapps-updater, openapps-licensing, apps/hertz); only `prefix`
/// differs. Keep them identical otherwise.
final class TemporaryDefaults: @unchecked Sendable {
    /// Every suite this package's tests make starts with this; the guard
    /// test (`DefaultsLeakGuardTests`) looks for files carrying it where
    /// none may be.
    static let prefix = "openapps-updater-tests."

    /// The suite's name: the path of its plist, without the extension.
    let suite: String
    let defaults: UserDefaults
    /// The suite's own directory under the temporary directory.
    let directory: URL
    private let lock = NSLock()
    private var removed = false

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = directory.appendingPathComponent("defaults").path
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit { remove() }

    /// Where the suite is kept.
    var fileURL: URL { URL(fileURLWithPath: suite + ".plist") }

    /// Clears the suite and deletes its directory. Safe to call more than once.
    func remove() {
        let first: Bool = lock.withLock {
            defer { removed = true }
            return !removed
        }
        guard first else { return }
        defaults.removePersistentDomain(forName: suite)
        defaults.removeSuite(named: suite)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The guard's view

    static var preferencesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// Where no suite could have been written, there is nothing to check.
    static var preferencesDirectoryIsWritable: Bool {
        FileManager.default.isWritableFile(atPath: preferencesDirectory.path)
    }

    /// Suite files under `prefix` in `~/Library/Preferences`. There must be
    /// none: every suite lives under the temporary directory.
    static func leakedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: preferencesDirectory.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".plist") }
            .sorted()
    }
}

/// No test may leave a suite behind in `~/Library/Preferences`: every
/// suite is made through `TemporaryDefaults`, which keeps it under the
/// temporary directory and removes it again. Skipped where the preferences
/// directory is not writable, as nothing could have been written there.
@Suite("Defaults leak guard")
struct DefaultsLeakGuardTests {
    @Test(.enabled(if: TemporaryDefaults.preferencesDirectoryIsWritable))
    func aSuiteLivesInItsTemporaryDirectoryAndGoesWithIt() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set(true, forKey: "written")
        temporary.defaults.synchronize()
        #expect(FileManager.default.fileExists(atPath: temporary.fileURL.path), "cfprefsd wrote the suite out where it was told to")
        #expect(temporary.fileURL.path.hasPrefix(temporary.directory.path))
        #expect(!temporary.fileURL.path.hasPrefix(TemporaryDefaults.preferencesDirectory.path))
        temporary.remove()
        #expect(!FileManager.default.fileExists(atPath: temporary.directory.path), "removed again, directory and all")
    }

    @Test(.enabled(if: TemporaryDefaults.preferencesDirectoryIsWritable))
    func noSuiteFileIsLeftInPreferences() throws {
        let leaked = try TemporaryDefaults.leakedFiles()
        #expect(leaked.isEmpty, "left in \(TemporaryDefaults.preferencesDirectory.path): \(leaked)")
    }
}
