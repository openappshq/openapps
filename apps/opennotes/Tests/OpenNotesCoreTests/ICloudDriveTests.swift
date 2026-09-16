import XCTest
@testable import OpenNotesCore

/// A fake iCloud: whether the folder is ubiquitous, what downloads were
/// asked for, and the unresolved conflict versions a file holds.
final class FakeUbiquity: Ubiquity {
    var ubiquitous = false
    var downloadsRequested: [URL] = []
    var downloadError: (any Error)?
    var versions: [URL: [FakeVersion]] = [:]
    private(set) var unresolvedConflictVersionsCallCount = 0

    func isUbiquitous(_ url: URL) -> Bool { ubiquitous }

    func startDownloading(_ url: URL) throws {
        downloadsRequested.append(url)
        if let downloadError { throw downloadError }
    }

    func unresolvedConflictVersions(of url: URL) -> [any UbiquityConflictVersion] {
        unresolvedConflictVersionsCallCount += 1
        // Realistic: a version already marked resolved is not handed back again.
        return (versions[url] ?? []).filter { !$0.resolved }
    }
}

/// One unresolved version a fake `Ubiquity` hands back.
final class FakeVersion: UbiquityConflictVersion {
    var data: Data
    var device: String?
    var modified: Date?
    /// Run inside `contents()`, before the data is returned: lets a test
    /// change the file on disk between the version being read and the
    /// fresh comparison that follows.
    var onContents: (() -> Void)?
    var contentsError: (any Error)?
    private(set) var resolved = false

    init(data: String, device: String? = nil, modified: Date? = nil) {
        self.data = Data(data.utf8)
        self.device = device
        self.modified = modified
    }

    func contents() throws -> Data {
        onContents?()
        if let contentsError { throw contentsError }
        return data
    }
    func markResolved() { resolved = true }
}

/// The store over a folder iCloud Drive can do things to: `.icloud`
/// placeholders, a file replaced by rename, conflict versions, and a file
/// found missing that a later rescan must confirm before it is gone.
final class ICloudDriveTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)
    private var events: [StoreEvent] = []
    private var ubiquity: FakeUbiquity!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-icloud-tests-\(UUID().uuidString)", isDirectory: true)
        ubiquity = FakeUbiquity()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor private func makeStore(create: Bool = true) -> NoteStore {
        let store = NoteStore(folder: folder, ubiquity: ubiquity) { [self] in clock }
        store.onEvent = { [self] in events.append($0) }
        store.load(create: create)
        return store
    }

    private func write(_ name: String, _ contents: String) throws {
        try write(name, contents, in: folder)
    }

    private func write(_ name: String, _ contents: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - ICloudDrive helpers

    func testPlaceholderNameRoundTripsWithTheNoteID() {
        let id = NoteID("groceries")
        let name = ICloudDrive.placeholderName(for: id)
        XCTAssertEqual(name, ".groceries.md.icloud")
        XCTAssertEqual(ICloudDrive.note(forPlaceholderName: name), id)
    }

    func testNamesThatAreNotPlaceholdersAreNotRecognized() {
        XCTAssertNil(ICloudDrive.note(forPlaceholderName: ".foo.txt.icloud"))
        XCTAssertNil(ICloudDrive.note(forPlaceholderName: "foo.md"))
        XCTAssertNil(ICloudDrive.note(forPlaceholderName: ".md.icloud"))
    }

    func testContainsChecksTheFolderIsUnderICloudDrivesRoot() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-home-\(UUID().uuidString)", isDirectory: true)
        let cloudDocs = ICloudDrive.cloudDocs(home: home)
        XCTAssertTrue(ICloudDrive.contains(cloudDocs, home: home))
        XCTAssertTrue(ICloudDrive.contains(cloudDocs.appendingPathComponent("OpenNotes"), home: home))
        XCTAssertFalse(ICloudDrive.contains(home.appendingPathComponent("Documents"), home: home))
    }

    func testIsAvailableOnlyWhenTheCloudDocsFolderExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertFalse(ICloudDrive.isAvailable(home: home))
        try FileManager.default.createDirectory(at: ICloudDrive.cloudDocs(home: home), withIntermediateDirectories: true)
        XCTAssertTrue(ICloudDrive.isAvailable(home: home))
    }

    // MARK: - Placeholder listing

    @MainActor func testAPlaceholderIsListedAsANoteWaitingToDownload() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        events = []
        try write(".b.md.icloud", "placeholder")
        store.rescan()
        XCTAssertEqual(Set(store.active.map(\.id)), Set([NoteID("a"), NoteID("b")]))
        let b = try XCTUnwrap(store.note(NoteID("b")))
        XCTAssertTrue(b.isDownloading)
        XCTAssertFalse(b.bodyIsLoaded)
        XCTAssertEqual(b.text, "b")
        XCTAssertTrue(events.contains(.updated([NoteID("b")])))
        XCTAssertEqual(store.storageStatus, .notDownloaded(count: 1, requested: 0))
        XCTAssertThrowsError(try store.setText("x", for: NoteID("b"))) {
            XCTAssertEqual($0 as? StoreError, .bodyUnavailable(NoteID("b")))
        }
        XCTAssertEqual(try store.save(NoteID("b")), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.md").path))
    }

    // MARK: - Download trigger

    @MainActor func testOpeningAPlaceholderAsksICloudToDownloadItOnce() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(".b.md.icloud", "placeholder")
        let store = makeStore()
        XCTAssertEqual(store.storageStatus, .notDownloaded(count: 1, requested: 0))
        _ = store.body(of: NoteID("b"))
        XCTAssertEqual(ubiquity.downloadsRequested, [folder.appendingPathComponent("b.md")])
        _ = store.body(of: NoteID("b"))
        XCTAssertEqual(ubiquity.downloadsRequested.count, 1, "asked once, not again")
        XCTAssertEqual(store.storageStatus, .notDownloaded(count: 1, requested: 1))
        // The file arrives: downloaded (or the eviction undone).
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".b.md.icloud"))
        try write("b.md", "b text")
        store.rescan()
        let b = try XCTUnwrap(store.note(NoteID("b")))
        XCTAssertEqual(b.text, "b text")
        XCTAssertFalse(b.isDownloading)
        XCTAssertEqual(store.storageStatus, .allOnThisMac)
    }

    @MainActor func testADownloadRequestThatFailsIsShownAsAProblem() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(".b.md.icloud", "placeholder")
        ubiquity.downloadError = CocoaError(.fileWriteUnknown)
        let store = makeStore()
        XCTAssertNil(store.downloadProblem)
        _ = store.body(of: NoteID("b"))
        let problem = try XCTUnwrap(store.downloadProblem)
        XCTAssertTrue(problem.contains("b.md"), problem)
    }

    // MARK: - Eviction while held

    @MainActor func testAnEvictedNoteHeldOpenWaitsForTheFileToReturn() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        // Evicted: the file is replaced by iCloud's placeholder.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        try write(".a.md.icloud", "placeholder")
        XCTAssertThrowsError(try store.save(NoteID("a"))) {
            XCTAssertEqual($0 as? StoreError, .waitingForDownload(NoteID("a")))
        }
        XCTAssertEqual(ubiquity.downloadsRequested, [folder.appendingPathComponent("a.md")])
        XCTAssertTrue(store.hasUnsavedChanges(NoteID("a")))
        XCTAssertEqual(store.storageStatus, .waiting)
        let note = try XCTUnwrap(store.note(NoteID("a")))
        XCTAssertEqual(note.text, "Ours")
        XCTAssertTrue(note.isDownloading)
        // The file is back, with its ORIGINAL content (a new inode): no
        // conflict copy, since identity is the content hash, not the inode.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".a.md.icloud"))
        try write("a.md", "A")
        XCTAssertEqual(try store.save(NoteID("a")), .saved)
        XCTAssertEqual(try files(), ["a.md"])
        XCTAssertTrue(try read("a.md").hasSuffix("\n\nOurs"))
    }

    // MARK: - Replaced by rename keeps identity

    @MainActor func testAFileReplacedByRenameWithTheSameBytesKeepsItsIdentity() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try write("a.tmp", "A")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("a.tmp"), to: folder.appendingPathComponent("a.md"))
        XCTAssertEqual(try store.save(NoteID("a")), .saved)
        XCTAssertEqual(try files(), ["a.md"])
        XCTAssertTrue(try read("a.md").hasSuffix("\n\nOurs"))
    }

    @MainActor func testAFileReplacedByRenameWithDifferentBytesDivertsToAConflictCopy() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try write("a.tmp", "Theirs, changed")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("a.tmp"), to: folder.appendingPathComponent("a.md"))
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try read("a.md"), "Theirs, changed")
        XCTAssertTrue(try read(copy.fileName).hasSuffix("\n\nOurs"))
    }

    // MARK: - Conflict versions

    @MainActor func testConflictVersionsAreMaterialisedAsNamedCopiesBesideTheFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "Mine")
        ubiquity.ubiquitous = true
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = folder.appendingPathComponent("a.md")
        let version = FakeVersion(data: "Theirs from the other Mac", device: "Kevin's MacBook", modified: date)
        ubiquity.versions[url] = [version]
        let store = makeStore()
        XCTAssertTrue(store.folderIsUbiquitous)
        let stem = NoteFileName.conflictStem(for: NoteID("a"), device: "Kevin's MacBook", at: date)
        XCTAssertEqual(try read(stem + ".md"), "Theirs from the other Mac")
        XCTAssertTrue(version.resolved)
        let copy = try XCTUnwrap(store.note(NoteID(stem)))
        XCTAssertEqual(copy.text, "Theirs from the other Mac")
    }

    func testConflictStemNamingMatchesNoteFileName() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let withDevice = NoteFileName.conflictStem(for: NoteID("a"), device: "Kevin's MacBook", at: date)
        let withoutDevice = NoteFileName.conflictStem(for: NoteID("a"), at: date)
        XCTAssertTrue(withDevice.hasPrefix("a (conflict from kevin-s-macbook "), withDevice)
        XCTAssertTrue(withDevice.hasSuffix(")"), withDevice)
        XCTAssertTrue(withoutDevice.hasPrefix("a (conflict "), withoutDevice)
        XCTAssertFalse(withoutDevice.contains("from"), withoutDevice)
        // A nil device gives the plain stem.
        XCTAssertEqual(NoteFileName.conflictStem(for: NoteID("a"), device: nil, at: date), withoutDevice)
    }

    @MainActor func testAConflictVersionIdenticalToTheFileIsResolvedWithoutACopy() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "Mine")
        ubiquity.ubiquitous = true
        let url = folder.appendingPathComponent("a.md")
        let version = FakeVersion(data: "Mine")
        ubiquity.versions[url] = [version]
        let store = makeStore()
        XCTAssertTrue(version.resolved)
        XCTAssertEqual(try files(), ["a.md"])
        XCTAssertEqual(store.notes.count, 1)
    }

    @MainActor func testNonUbiquitousFoldersNeverAskForConflictVersions() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "Mine")
        ubiquity.ubiquitous = false
        let url = folder.appendingPathComponent("a.md")
        ubiquity.versions[url] = [FakeVersion(data: "Theirs")]
        let store = makeStore()
        XCTAssertFalse(store.folderIsUbiquitous)
        XCTAssertEqual(ubiquity.unresolvedConflictVersionsCallCount, 0)
        store.rescan()
        XCTAssertEqual(ubiquity.unresolvedConflictVersionsCallCount, 0)
    }

    // MARK: - Confirmed-gone deletes

    @MainActor func testAFileGoingMissingIsRemovedOnlyAfterTheGrace() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        events = []
        store.rescan()
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertEqual(store.pendingRemovals, [NoteID("a")])
        XCTAssertEqual(events, [])
        // A second rescan, the clock not advanced: still pending.
        store.rescan()
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertEqual(events, [])
        clock += NoteStore.removalGrace
        store.rescan()
        XCTAssertEqual(events, [.removed([NoteID("a")])])
        XCTAssertNil(store.note(NoteID("a")))
        XCTAssertEqual(store.pendingRemovals, [])
    }

    @MainActor func testATransientDisappearanceNeverRemovesTheNote() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        events = []
        store.rescan()
        XCTAssertEqual(store.pendingRemovals, [NoteID("a")])
        try write("a.md", "A")
        store.rescan()
        XCTAssertEqual(events, [])
        XCTAssertEqual(store.pendingRemovals, [])
        let note = try XCTUnwrap(store.note(NoteID("a")))
        XCTAssertEqual(note.text, "A")
    }

    @MainActor func testADirtyNoteWhoseFileWentIsNeverRemoved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        clock += NoteStore.removalGrace * 3
        store.rescan()
        store.rescan()
        let note = try XCTUnwrap(store.note(NoteID("a")))
        XCTAssertEqual(note.text, "Ours")
        XCTAssertEqual(store.pendingRemovals, [])
    }

    // MARK: - Copy on switch

    @MainActor func testSwitchingFoldersCopiesNotesAndReportsWhatHappened() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        try write("b.md", "B ours")
        try write(".c.md.icloud", "placeholder")
        let store = makeStore()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-dest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try write("a.md", "A", in: dest)
        try write("b.md", "B theirs", in: dest)

        let report = try store.switchFolder(to: dest, create: true, copyingNotes: true)

        XCTAssertEqual(report.copied, 0)
        XCTAssertEqual(report.identical, 1)
        XCTAssertEqual(report.conflictCopies, 1)
        XCTAssertEqual(report.notDownloaded, 1)
        XCTAssertNotNil(report.summary)
        XCTAssertEqual(store.folder, dest)

        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.md"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("b.md"), encoding: .utf8), "B theirs")
        let destNames = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        let conflictName = try XCTUnwrap(destNames.first { $0.hasPrefix("b (conflict") })
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent(conflictName), encoding: .utf8), "B ours")

        // The old folder is untouched.
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.md"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.md"), encoding: .utf8), "B ours")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".c.md.icloud").path))
    }

    @MainActor func testSwitchingFoldersCreatesTheDestinationWhenMissing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        try write("b.md", "B")
        let store = makeStore()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-dest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let report = try store.switchFolder(to: dest, create: true, copyingNotes: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(report.copied, 2)
        XCTAssertEqual(report.identical, 0)
        XCTAssertEqual(report.conflictCopies, 0)
    }

    @MainActor func testSwitchingFoldersWithoutCopyingNotesCopiesNothing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-dest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let report = try store.switchFolder(to: dest, create: true)
        XCTAssertEqual(report, FolderSwitchReport())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [])
    }

    @MainActor func testSwitchingFoldersWhileReadOnlyThrowsAndCopiesNothing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        store.access = { false }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-dest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertThrowsError(try store.switchFolder(to: dest, create: true, copyingNotes: true)) {
            XCTAssertEqual($0 as? StoreError, .readOnly)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(store.folder, folder)
    }

    // MARK: - StorageStatus

    func testStorageStatusText() {
        XCTAssertEqual(StorageStatus.allOnThisMac.text, "all notes on this Mac")
        XCTAssertEqual(StorageStatus.notDownloaded(count: 3, requested: 0).text, "3 not downloaded")
        XCTAssertEqual(StorageStatus.notDownloaded(count: 3, requested: 2).text, "downloading 2 of 3")
        XCTAssertEqual(StorageStatus.waiting.text, "waiting for iCloud")
    }

    // MARK: - Copy on switch: destination placeholders

    @MainActor func testCopyOnSwitchSkipsADestinationPlaceholderAndAConflictNamePlaceholder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "LOCAL")
        let store = makeStore()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-dest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try write(".a.md.icloud", "placeholder", in: dest)
        let base = NoteFileName.conflictStem(for: NoteID("a"), at: clock)
        try write(ICloudDrive.placeholderName(for: NoteID(base)), "placeholder", in: dest)

        let report = try store.switchFolder(to: dest, create: true, copyingNotes: true)

        XCTAssertEqual(report.copied, 0)
        XCTAssertEqual(report.conflictCopies, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".a.md.icloud").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent(ICloudDrive.placeholderName(for: NoteID(base))).path))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("\(base)-2.md"), encoding: .utf8), "LOCAL")
    }

    // MARK: - isOccupied through public paths

    @MainActor func testFinishProvisionalSkipsATitleNameThatIsAPlaceholder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(".groceries.md.icloud", "placeholder")
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("Groceries", for: note.id)
        let finalID = try store.finishProvisional(note.id)
        XCTAssertEqual(finalID, NoteID("groceries-2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("groceries.md").path))
        XCTAssertTrue(try read("groceries-2.md").hasSuffix("\n\nGroceries"))
    }

    @MainActor func testAConflictCopyNameThatIsAPlaceholderIsSkipped() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        let base = NoteFileName.conflictStem(for: NoteID("a"), at: clock)
        try write(ICloudDrive.placeholderName(for: NoteID(base)), "placeholder")
        try write("a.md", "Theirs, longer")
        store.rescan()
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(copy, NoteID("\(base)-2"))
        XCTAssertTrue(try read(copy.fileName).hasSuffix("\n\nOurs"))
    }

    // MARK: - Fresh comparison at resolve time

    @MainActor func testAConflictVersionIsReComparedAgainstTheFileAtResolveTime() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        ubiquity.ubiquitous = true
        let url = folder.appendingPathComponent("a.md")
        let version = FakeVersion(data: "A")
        version.onContents = { [self] in try? write("a.md", "B") }
        ubiquity.versions[url] = [version]
        let base = NoteFileName.conflictStem(for: NoteID("a"), at: clock)
        _ = makeStore()
        XCTAssertTrue(version.resolved)
        XCTAssertEqual(try read(base + ".md"), "A")
        XCTAssertEqual(try read("a.md"), "B")
    }

    // MARK: - Conflict versions while read-only

    @MainActor func testConflictVersionsWaitForALicenseWhileReadOnlyThenMaterialiseOnceAllowed() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "Mine")
        ubiquity.ubiquitous = true
        let store = makeStore()
        store.access = { false }
        let url = folder.appendingPathComponent("a.md")
        let version = FakeVersion(data: "Theirs")
        ubiquity.versions[url] = [version]
        let base = NoteFileName.conflictStem(for: NoteID("a"), at: clock)

        store.rescan()
        XCTAssertFalse(version.resolved)
        XCTAssertEqual(store.conflictVersionsWaiting, 1)
        XCTAssertEqual(store.storageStatus, .conflictsWaiting(1))
        XCTAssertEqual(store.storageStatus.text, "1 conflict version waits for a license")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(base + ".md").path))

        store.access = { true }
        store.rescan()
        XCTAssertTrue(version.resolved)
        XCTAssertEqual(store.conflictVersionsWaiting, 0)
        XCTAssertEqual(try read(base + ".md"), "Theirs")
    }

    // MARK: - Conflict problems surfaced

    @MainActor func testAConflictVersionThatCannotBeReadIsAProblemThenResolvesOnceItCan() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "Mine")
        ubiquity.ubiquitous = true
        let url = folder.appendingPathComponent("a.md")
        let version = FakeVersion(data: "Theirs")
        version.contentsError = CocoaError(.fileReadUnknown)
        ubiquity.versions[url] = [version]
        let base = NoteFileName.conflictStem(for: NoteID("a"), at: clock)
        let store = makeStore()

        let problem = try XCTUnwrap(store.conflictProblem)
        XCTAssertTrue(problem.contains("a.md"), problem)
        XCTAssertFalse(version.resolved)

        version.contentsError = nil
        store.rescan()
        XCTAssertNil(store.conflictProblem)
        XCTAssertTrue(version.resolved)
        XCTAssertEqual(try read(base + ".md"), "Theirs")

        // No second copy: the version is not handed back once resolved.
        store.rescan()
        XCTAssertEqual(try files(), [base + ".md", "a.md"])
    }

    // MARK: - Refused downloads retry

    @MainActor func testARefusedDownloadIsRetriedOnEveryOpenAndByRescan() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(".b.md.icloud", "placeholder")
        ubiquity.downloadError = CocoaError(.fileWriteUnknown)
        let store = makeStore()

        _ = store.body(of: NoteID("b"))
        XCTAssertNotNil(store.downloadProblems[NoteID("b")])
        XCTAssertEqual(ubiquity.downloadsRequested.count, 1)
        let problem = try XCTUnwrap(store.downloadProblem)
        XCTAssertTrue(problem.hasPrefix("b.md: "), problem)

        _ = store.body(of: NoteID("b"))
        XCTAssertEqual(ubiquity.downloadsRequested.count, 2, "retried, not suppressed")

        ubiquity.downloadError = nil
        store.rescan()
        XCTAssertEqual(ubiquity.downloadsRequested.count, 3)
        XCTAssertNil(store.downloadProblems[NoteID("b")])

        _ = store.body(of: NoteID("b"))
        XCTAssertEqual(ubiquity.downloadsRequested.count, 3, "accepted once")
    }

    // MARK: - Folder guard

    @MainActor func testSaveRefusesWhenTheFolderIsReplacedByALinkElsewhereThenSucceedsOnceRestored() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))

        let aside = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-aside-\(UUID().uuidString)", isDirectory: true)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write("a.md", "Elsewhere", in: elsewhere)
        try FileManager.default.moveItem(at: folder, to: aside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try store.save(NoteID("a"))) {
            XCTAssertEqual($0 as? StoreError, .folderReplaced(folder))
        }
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("a.md"), encoding: .utf8), "Elsewhere")
        XCTAssertTrue(store.hasUnsavedChanges(NoteID("a")))

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: aside, to: folder)
        XCTAssertEqual(try store.save(NoteID("a")), .saved)
        XCTAssertTrue(try read("a.md").hasSuffix("\n\nOurs"))
    }

    @MainActor func testDiscardIfEmptyRefusesAndUnlinksNothingWhenTheFolderIsReplacedByALink() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("x", for: note.id)
        XCTAssertEqual(try store.save(note.id), .saved)
        try store.setText("", for: note.id)

        let aside = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-aside-\(UUID().uuidString)", isDirectory: true)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write(note.id.fileName, "Linked directory's own file", in: elsewhere)
        try FileManager.default.moveItem(at: folder, to: aside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        XCTAssertFalse(store.discardIfEmpty(note.id))
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent(note.id.fileName), encoding: .utf8), "Linked directory's own file")

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: aside, to: folder)
    }

    // MARK: - Export of a placeholder note

    @MainActor func testExportingAPlaceholderThrowsBodyUnavailable() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(".b.md.icloud", "placeholder")
        let store = makeStore()
        XCTAssertThrowsError(try store.export(NoteID("b"), as: .markdown)) {
            XCTAssertEqual($0 as? StoreError, .bodyUnavailable(NoteID("b")))
        }
    }

    // MARK: - License lapses mid-read

    @MainActor func testLicenseLapsingDuringTheVersionReadPreventsResolution() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "B")
        ubiquity.ubiquitous = true
        let url = folder.appendingPathComponent("a.md")
        let store = makeStore()

        let version = FakeVersion(data: "A")
        var lapsed = false
        version.onContents = {
            guard !lapsed else { return }
            lapsed = true
            store.access = { false }
        }
        ubiquity.versions[url] = [version]
        let base = NoteFileName.conflictStem(for: NoteID("a"), at: clock)

        store.rescan()
        XCTAssertFalse(version.resolved)
        XCTAssertEqual(store.conflictVersionsWaiting, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(base + ".md").path))

        store.access = { true }
        store.rescan()
        XCTAssertTrue(version.resolved)
        XCTAssertEqual(store.conflictVersionsWaiting, 0)
        XCTAssertEqual(try read(base + ".md"), "A")
    }

    @MainActor func testLicenseLapsingDuringAnIdenticalVersionReadStillCountsAsWaiting() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        ubiquity.ubiquitous = true
        let url = folder.appendingPathComponent("a.md")
        let store = makeStore()

        let version = FakeVersion(data: "A")
        version.onContents = { store.access = { false } }
        ubiquity.versions[url] = [version]

        store.rescan()
        XCTAssertFalse(version.resolved)
        XCTAssertEqual(store.conflictVersionsWaiting, 1)
        XCTAssertEqual(try files(), ["a.md"])
    }

    // MARK: - Recovery while read-only

    @MainActor func testRecoveryWhileReadOnlyLeavesTemporariesInPlace() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let tempName = ".a.md.tmp-" + UUID().uuidString
        try write(tempName, "stranded bytes")
        let store = NoteStore(folder: folder, ubiquity: ubiquity) { [self] in clock }
        store.onEvent = { [self] in events.append($0) }
        store.access = { false }
        store.load(create: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(tempName).path))
        XCTAssertTrue(try files().filter { $0.contains("(recovered") }.isEmpty)
        XCTAssertEqual(store.strandedTemporariesWaiting, 1)
        XCTAssertEqual(store.storageStatus, .recoveriesWaiting(1))
        XCTAssertEqual(store.storageStatus.text, "1 recovered version waits for a license")

        store.access = { true }
        store.rescan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(tempName).path))
        XCTAssertEqual(try files().filter { $0.contains("(recovered") }.count, 1)
        XCTAssertEqual(store.strandedTemporariesWaiting, 0)
    }

    // MARK: - Recovery folder guard

    @MainActor func testRecoveryRefusesWhenTheFolderIsReplacedByALinkElsewhere() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()

        let aside = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-aside-\(UUID().uuidString)", isDirectory: true)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write("a.md", "Elsewhere", in: elsewhere)
        let tempName = ".a.md.tmp-" + UUID().uuidString
        try write(tempName, "stranded bytes", in: elsewhere)
        try FileManager.default.moveItem(at: folder, to: aside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        store.rescan()
        let problem = try XCTUnwrap(store.recoveryProblem)
        XCTAssertTrue(problem.contains("leads somewhere else"), problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent(tempName).path))
        let recoveredInElsewhere = try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).filter { $0.contains("(recovered") }
        XCTAssertTrue(recoveredInElsewhere.isEmpty)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: aside, to: folder)
        store.rescan()
        XCTAssertNil(store.recoveryProblem)
    }

    // MARK: - Recovery never masks a placeholder

    @MainActor func testRecoveryNeverMasksAPlaceholder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tempName = ".a.md.tmp-" + UUID().uuidString
        try write(tempName, "stranded bytes")
        let base = NoteFileName.recoveredStem(for: "a", at: clock)
        let placeholderName = ICloudDrive.placeholderName(for: NoteID(base))
        try write(placeholderName, "placeholder")

        let store = makeStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(base + ".md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(placeholderName).path))
        XCTAssertEqual(try read("\(base)-2.md"), "stranded bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(tempName).path))
        XCTAssertEqual(store.strandedTemporariesWaiting, 0)
    }
}
