import XCTest
@testable import HertzCore

/// Runs the scout against a throwaway home directory, never the real one.
/// The scout is read-only; every test also asserts that nothing it touched
/// changed on disk.
final class CleanupScoutTests: XCTestCase {
    private var home: URL!

    /// A fresh home per test, removed when the test ends.
    private func makeHome() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hertz-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let home = self.home!
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    }

    private func write(_ relativePath: String, bytes: Int = 4096, under root: URL? = nil) throws {
        let url = (root ?? home).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func touch(_ relativePath: String, modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: home.appendingPathComponent(relativePath).path)
    }

    private func exists(_ relativePath: String, under root: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (root ?? home).appendingPathComponent(relativePath).path)
    }

    /// Every regular file under `root`, relative, so a before/after comparison
    /// proves the scan changed nothing.
    private func listing(_ root: URL) -> Set<String> {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [], errorHandler: nil)!
        var files: Set<String> = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.insert(String(url.path.dropFirst(root.path.count)))
        }
        return files
    }

    @MainActor func testScanFindsOnlyAllowlistedCachesAndChangesNothing() throws {
        try makeHome()
        try write("Library/Caches/org.swift.swiftpm/repositories/a/pack", bytes: 20_000)
        try write("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 10_000)
        try write("Documents/thesis.txt")
        try write("Library/Application Support/App/data.db")
        try write("Library/Caches/com.example.app/data")
        let before = listing(home)

        let scan = CleanupScout(homeDirectory: home).scan()
        XCTAssertEqual(scan.candidates.map(\.title), ["SwiftPM cache", "Homebrew downloads"])
        XCTAssertTrue(scan.skipped.isEmpty)
        XCTAssertGreaterThanOrEqual(scan.totalBytes, 30_000)
        XCTAssertGreaterThanOrEqual(scan.itemCount, 2, "files and the folders holding them")
        XCTAssertEqual(listing(home), before, "a scan is read-only")
    }

    @MainActor func testDerivedDataListsOnlyProjectsOlderThanTwelveHours() throws {
        try makeHome()
        try write("Library/Developer/Xcode/DerivedData/Old-abc/Build/x.o")
        try touch("Library/Developer/Xcode/DerivedData/Old-abc", modified: Date().addingTimeInterval(-2 * 86400))
        try write("Library/Developer/Xcode/DerivedData/Fresh-def/Build/y.o")
        let scan = CleanupScout(homeDirectory: home).scan()
        XCTAssertEqual(scan.candidates.map(\.title), ["DerivedData: Old-abc"])
        XCTAssertTrue(exists("Library/Developer/Xcode/DerivedData/Old-abc/Build/x.o"))
    }

    @MainActor func testSymlinkedCacheIsNotFollowed() throws {
        try makeHome()
        try write("Documents/precious.txt")
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("org.swift.swiftpm"),
                                                   withDestinationURL: home.appendingPathComponent("Documents"))
        let scan = CleanupScout(homeDirectory: home).scan()
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.skipped, [caches.appendingPathComponent("org.swift.swiftpm").path])
        XCTAssertTrue(exists("Documents/precious.txt"))
    }

    /// The reviewer's scenario: an ancestor of an allowlisted root replaced by
    /// a symlink to a directory outside the home. Nothing behind it may be
    /// listed, and nothing anywhere may change.
    @MainActor func testAncestorSymlinkOutsideTheHomeIsRefused() throws {
        try makeHome()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("hertz-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try write("DerivedData/project/precious.txt", under: outside)
        try write("Homebrew/downloads/bottle.tar.gz", under: outside)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)],
                                              ofItemAtPath: outside.appendingPathComponent("DerivedData/project").path)
        // ~/Library/Developer/Xcode → outside (a children-mode root behind the link)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Developer"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Developer/Xcode"), withDestinationURL: outside)
        // ~/Library/Caches → outside (a contents-mode root behind the link)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Caches"), withDestinationURL: outside)
        let before = listing(outside)

        let scan = CleanupScout(homeDirectory: home).scan()
        XCTAssertTrue(scan.candidates.isEmpty, "\(scan.candidates.map(\.path))")
        // Every allowlisted root behind either link is reported as skipped,
        // by the path Hertz would have scanned, never by where the link goes.
        XCTAssertTrue(scan.skipped.contains(home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path))
        XCTAssertTrue(scan.skipped.contains(home.appendingPathComponent("Library/Caches/Homebrew/downloads").path))
        XCTAssertTrue(scan.skipped.allSatisfy { $0.hasPrefix(home.path + "/Library/") }, "\(scan.skipped)")
        XCTAssertEqual(listing(outside), before)
    }

    @MainActor func testReportNamesEveryCandidateAndSkippedPathAndSaysNothingWasRemoved() throws {
        try makeHome()
        let scan = CleanupScan(candidates: [
            CleanupCandidate(title: "npm logs", category: "Node", reason: "Log files.", path: "/h/.npm/_logs",
                             bytes: 2 * 1_048_576, itemCount: 3),
        ], skipped: ["/h/Library/Caches/link"])
        let report = CleanupScout(homeDirectory: home).report(for: scan)
        XCTAssertTrue(report.contains("Regenerable: 2 MB across 1 cache groups (nothing was removed)"))
        XCTAssertTrue(report.contains("- npm logs: 2 MB\n  Log files.\n  /h/.npm/_logs"))
        XCTAssertTrue(report.contains("Skipped protected paths:\n- /h/Library/Caches/link"))
    }
}
