import XCTest
@testable import HertzCore

/// Runs the scout against a throwaway home directory, never the real one.
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

    private func write(_ relativePath: String, bytes: Int = 4096, modified: Date? = nil) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func touch(_ relativePath: String, modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: home.appendingPathComponent(relativePath).path)
    }

    @MainActor func testScanFindsOnlyAllowlistedCachesAndCleansTheirContents() throws {
        try makeHome()
        try write("Library/Caches/org.swift.swiftpm/repositories/a/pack", bytes: 20_000)
        try write("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 10_000)
        try write("Documents/thesis.txt")
        try write("Library/Application Support/App/data.db")
        let scout = CleanupScout(homeDirectory: home)

        let scan = scout.scan()
        XCTAssertEqual(scan.candidates.map(\.title), ["SwiftPM cache", "Homebrew downloads"])
        XCTAssertTrue(scan.candidates.allSatisfy(\.deleteContents))
        XCTAssertTrue(scan.skipped.isEmpty)
        XCTAssertGreaterThanOrEqual(scan.totalBytes, 30_000)

        let result = scout.clean(scan.candidates)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.cleanedItems, scan.itemCount)
        // The cache folders survive; their contents are gone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/org.swift.swiftpm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/org.swift.swiftpm/repositories").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/Homebrew/downloads/bottle.tar.gz").path))
        // Nothing outside the allowlist was touched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/thesis.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/App/data.db").path))
        XCTAssertTrue(scout.scan().candidates.isEmpty)
    }

    @MainActor func testDerivedDataListsOnlyProjectsOlderThanTwelveHours() throws {
        try makeHome()
        try write("Library/Developer/Xcode/DerivedData/Old-abc/Build/x.o")
        try touch("Library/Developer/Xcode/DerivedData/Old-abc", modified: Date().addingTimeInterval(-2 * 86400))
        try write("Library/Developer/Xcode/DerivedData/Fresh-def/Build/y.o")
        let scan = CleanupScout(homeDirectory: home).scan()
        XCTAssertEqual(scan.candidates.map(\.title), ["DerivedData: Old-abc"])
        XCTAssertEqual(scan.candidates.first?.deleteContents, false, "a stale project folder is removed whole")

        let result = CleanupScout(homeDirectory: home).clean(scan.candidates)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Old-abc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Fresh-def/Build/y.o").path))
    }

    @MainActor func testCleanRefusesPathsOutsideTheHomeOrInProtectedFolders() throws {
        try makeHome()
        try write("Documents/keep.txt")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("hertz-outside-\(UUID().uuidString).txt")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let forged = [
            CleanupCandidate(title: "Documents", category: "x", reason: "", path: home.appendingPathComponent("Documents").path,
                             bytes: 1, itemCount: 1, deleteContents: true),
            CleanupCandidate(title: "Outside", category: "x", reason: "", path: outside.path,
                             bytes: 1, itemCount: 1, deleteContents: false),
            CleanupCandidate(title: "Escape", category: "x", reason: "",
                             path: home.appendingPathComponent("Library/Caches/../../Documents/keep.txt").path,
                             bytes: 1, itemCount: 1, deleteContents: false),
            CleanupCandidate(title: "Unlisted cache", category: "x", reason: "", path: home.appendingPathComponent("Library/Caches/com.example.app").path,
                             bytes: 1, itemCount: 1, deleteContents: true),
            CleanupCandidate(title: "Too deep", category: "x", reason: "",
                             path: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Proj/Build").path,
                             bytes: 1, itemCount: 1, deleteContents: false),
            CleanupCandidate(title: "Review", category: "x", reason: "", path: home.appendingPathComponent("Library/Caches/pip").path,
                             bytes: 1, itemCount: 1, risk: .review, deleteContents: true),
        ]
        try write("Library/Caches/com.example.app/data")
        try write("Library/Developer/Xcode/DerivedData/Proj/Build/x.o")
        let result = CleanupScout(homeDirectory: home).clean(forged)
        XCTAssertEqual(result.cleanedItems, 0)
        XCTAssertEqual(Set(result.failed), Set(forged.prefix(5).map(\.path)), "review-risk candidates are skipped silently")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.app/data").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Proj/Build/x.o").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    @MainActor func testSymlinkedCacheIsNotFollowed() throws {
        try makeHome()
        try write("Documents/precious.txt")
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("org.swift.swiftpm"),
                                                   withDestinationURL: home.appendingPathComponent("Documents"))
        let scout = CleanupScout(homeDirectory: home)
        let scan = scout.scan()
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.skipped, [caches.appendingPathComponent("org.swift.swiftpm").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/precious.txt").path))
    }

    @MainActor func testReportNamesEveryCandidateAndSkippedPath() throws {
        try makeHome()
        let scan = CleanupScan(candidates: [
            CleanupCandidate(title: "npm logs", category: "Node", reason: "Log files.", path: "/h/.npm/_logs",
                             bytes: 2 * 1_048_576, itemCount: 3, deleteContents: true),
        ], skipped: ["/h/Library/Caches/link"])
        let report = CleanupScout(homeDirectory: home).report(for: scan)
        XCTAssertTrue(report.contains("Reclaimable: 2 MB across 1 safe groups"))
        XCTAssertTrue(report.contains("- npm logs: 2 MB\n  Log files.\n  /h/.npm/_logs"))
        XCTAssertTrue(report.contains("Skipped protected paths:\n- /h/Library/Caches/link"))
    }
}
