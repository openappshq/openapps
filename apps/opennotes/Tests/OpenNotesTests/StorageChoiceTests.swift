import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// A fake iCloud, copied here since test targets don't share sources
/// (ICloudDriveTests.swift in OpenNotesCoreTests has the fuller one).
private final class FakeUbiquity: Ubiquity {
    var ubiquitous = false
    var downloadsRequested: [URL] = []
    var downloadError: (any Error)?
    var versions: [URL: [FakeVersion]] = [:]

    func isUbiquitous(_ url: URL) -> Bool { ubiquitous }

    func startDownloading(_ url: URL) throws {
        downloadsRequested.append(url)
        if let downloadError { throw downloadError }
    }

    func unresolvedConflictVersions(of url: URL) -> [any UbiquityConflictVersion] {
        (versions[url] ?? []).filter { !$0.resolved }
    }
}

/// One unresolved version a fake `Ubiquity` hands back.
private final class FakeVersion: UbiquityConflictVersion {
    var data: Data
    var device: String?
    var modified: Date?
    var contentsError: (any Error)?
    private(set) var resolved = false

    init(data: String) { self.data = Data(data.utf8) }

    func contents() throws -> Data {
        if let contentsError { throw contentsError }
        return data
    }
    func markResolved() { resolved = true }
}

// `MemoryFlags` (a `FlagStore` kept in memory) already lives in
// OnboardingTests.swift in this same target; reused here as is.

/// `FreshInstallDefault.display(store:)` directly: `wouldApply` is pure,
/// `markDecided` records it, whichever way it went.
final class FreshInstallDisplayDefaultTests: XCTestCase {
    func testWouldApplyOnceThenNeverAgainAfterMarkDecided() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.display(store: store)
        XCTAssertFalse(sut.hadPreferences)
        XCTAssertTrue(sut.wouldApply(isSet: false))
        XCTAssertFalse(sut.isDecided, "wouldApply alone never records anything")
        sut.markDecided()
        XCTAssertTrue(sut.isDecided)
        XCTAssertFalse(sut.wouldApply(isSet: false))
    }

    func testWouldApplyIsFalseWhenAChoiceIsAlreadySet() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.display(store: store)
        XCTAssertFalse(sut.wouldApply(isSet: true))
    }

    func testWouldApplyIsFalseWithEarlierEvidence() {
        let store = MemoryFlags()
        store.set(true, forKey: "notes.face")
        let sut = FreshInstallDefault.display(store: store)
        XCTAssertTrue(sut.hadPreferences)
        XCTAssertFalse(sut.wouldApply(isSet: false))
    }

    func testTheEvidenceListNamesTheDisplayFlag() {
        XCTAssertTrue(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(FreshInstallDefault.Key.displayApplied))
    }
}

/// `Preferences`' fresh-install display default: decided in memory at
/// `init`, and only written to storage once `commitLaunchDefaults` runs
/// (deferred so an earlier default's own write is never mistaken for an
/// earlier launch by the ones that read the evidence after it).
final class PreferencesDisplayDefaultTests: XCTestCase {
    @MainActor func testFreshInstallAppliesEveryDisplayOnlyOnceCommitted() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(preferences.display, .every)
        XCTAssertNil(temporary.defaults.string(forKey: Preferences.Key.display), "not written before commit")
        XCTAssertFalse(temporary.defaults.bool(forKey: FreshInstallDefault.Key.displayApplied))
        preferences.commitLaunchDefaults()
        XCTAssertEqual(temporary.defaults.string(forKey: Preferences.Key.display), "every")
        XCTAssertTrue(temporary.defaults.bool(forKey: FreshInstallDefault.Key.displayApplied))
        let again = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(again.display, .every)
    }

    @MainActor func testOtherEvidenceWrittenBeforeTheNextReadIsAnEarlierLaunchToIt() throws {
        let temporary = try TemporaryDefaults()
        let first = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(first.display, .every, "decided in memory, not yet committed")
        // Something else (the login item's own default) writes a preference
        // before this one commits.
        temporary.defaults.set("mono", forKey: "notes.face")
        let again = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(again.display, .main)
    }

    @MainActor func testEarlierPreferencesPresentAtConstructionKeepTheMainDisplay() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set("mono", forKey: "notes.face")
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(preferences.display, .main)
        preferences.commitLaunchDefaults()
        XCTAssertTrue(temporary.defaults.bool(forKey: FreshInstallDefault.Key.displayApplied), "recorded whichever way it went")
        XCTAssertNil(temporary.defaults.string(forKey: Preferences.Key.display), "the default itself is never written")
    }

    @MainActor func testAStoredDisplayChoiceOnAFreshSuiteIsKept() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set("pointer", forKey: "deck.display")
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(preferences.display, .pointer)
        preferences.commitLaunchDefaults()
        XCTAssertEqual(temporary.defaults.string(forKey: "deck.display"), "pointer")
    }
}

/// Where the notes live, read off the folder alone.
final class PreferencesStorageTests: XCTestCase {
    @MainActor func testStorageIsDerivedFromTheFolder() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(preferences.storage, .thisMac)
        XCTAssertTrue(preferences.createsFolder)

        preferences.folder = Preferences.iCloudFolder
        XCTAssertEqual(preferences.storage, .iCloudDrive)
        XCTAssertTrue(preferences.createsFolder)
        XCTAssertTrue(Preferences.iCloudFolder.path.hasSuffix("Library/Mobile Documents/com~apple~CloudDocs/OpenNotes"), Preferences.iCloudFolder.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Preferences.iCloudFolder.path), "setting the preference never creates the folder")

        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("chosen-\(UUID().uuidString)", isDirectory: true)
        preferences.folder = chosen
        XCTAssertEqual(preferences.storage, .other)
        XCTAssertFalse(preferences.createsFolder)

        preferences.setStorage(.thisMac)
        XCTAssertTrue(preferences.usesDefaultFolder)

        preferences.folder = chosen
        preferences.setStorage(.other)
        XCTAssertEqual(preferences.folder, chosen, "\"Other folder…\" is the chooser's job; setStorage(.other) itself changes nothing")
    }
}

/// `AppModel.setStorage`: the license decides, asked before anything else.
final class AppModelStorageTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel(startsRestricted: Bool) -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: startsRestricted), store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)
        return model
    }

    @MainActor func testReadOnlyRefusesChangingStorage() {
        let model = makeModel(startsRestricted: true)
        let before = model.preferences.folder
        XCTAssertFalse(model.setStorage(.other))
        XCTAssertEqual(model.preferences.folder, before)
    }

    @MainActor func testAllowedSetStorageOtherSucceedsButChangesNothingByItself() {
        // Do not test .iCloudDrive through the model: it depends on this
        // Mac's iCloud state and would create the real folder.
        let model = makeModel(startsRestricted: false)
        let before = model.preferences.folder
        XCTAssertTrue(model.setStorage(.other))
        XCTAssertEqual(model.preferences.folder, before)
    }
}

/// `AppModel.statusLine` and `storageStatusLine` over a fake iCloud.
final class AppModelICloudStatusTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var ubiquity: FakeUbiquity!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
        ubiquity = FakeUbiquity()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel() -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder, ubiquity: ubiquity), watcher: FolderWatcher())
        model.store.load(create: false)
        return model
    }

    @MainActor func testAPlaceholderNotesStatusLineSaysDownloading() throws {
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent(".x.md.icloud"))
        let model = makeModel()
        XCTAssertEqual(model.statusLine(for: NoteID("x")), "Downloading from iCloud Drive…")
    }

    @MainActor func testStorageStatusLineIsNilWhenTheFolderIsNotUbiquitous() throws {
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent(".x.md.icloud"))
        ubiquity.ubiquitous = false
        let model = makeModel()
        XCTAssertNil(model.storageStatusLine)
    }

    @MainActor func testStorageStatusLineShowsNotDownloadedThenDownloading() throws {
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent(".x.md.icloud"))
        ubiquity.ubiquitous = true
        let model = makeModel()
        XCTAssertEqual(model.preferences.storage, .other, "a temp folder is neither the default nor the iCloud Drive one")
        XCTAssertEqual(model.storageStatusLine, "In iCloud · 1 not downloaded")
        _ = model.body(of: NoteID("x"))
        XCTAssertEqual(model.storageStatusLine, "In iCloud · downloading 1 of 1")
    }

    @MainActor func testFolderProblemAndStorageStatusLineShowAConflictThatCouldNotBeRead() throws {
        try Data("Mine".utf8).write(to: folder.appendingPathComponent("a.md"))
        ubiquity.ubiquitous = true
        let url = folder.appendingPathComponent("a.md")
        let version = FakeVersion(data: "Theirs")
        version.contentsError = CocoaError(.fileReadUnknown)
        ubiquity.versions[url] = [version]
        let model = makeModel()
        let problem = try XCTUnwrap(model.folderProblem)
        XCTAssertTrue(problem.contains("a.md"), problem)
        XCTAssertEqual(model.storageStatusLine, "In iCloud · \(problem)")
    }

    @MainActor func testStatusLineShowsARefusedDownload() throws {
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent(".x.md.icloud"))
        ubiquity.ubiquitous = true
        ubiquity.downloadError = CocoaError(.fileWriteUnknown)
        let model = makeModel()
        _ = model.body(of: NoteID("x"))
        let line = model.statusLine(for: NoteID("x"))
        XCTAssertTrue(line.hasPrefix("iCloud Drive refused the download ("), line)
    }

    @MainActor func testStorageStatusLineForAnAllLocalUbiquitousFolderSaysAllNotesOnThisMac() throws {
        try Data("A".utf8).write(to: folder.appendingPathComponent("a.md"))
        ubiquity.ubiquitous = true
        let model = makeModel()
        XCTAssertEqual(model.storageStatusLine, "In iCloud · all notes on this Mac")
        XCTAssertFalse(StorageStatus.allOnThisMac.text.contains("up to date"))
    }
}

/// The model's follow-up rescan confirms a removal shortly after the first
/// one found nothing, without the watcher (which registers observers).
final class AppModelRemovalFollowUpTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor func testARescanFollowsUpToConfirmARemoval() throws {
        try Data("A".utf8).write(to: folder.appendingPathComponent("a.md"))
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        model.rescan()
        XCTAssertNotNil(model.note(NoteID("a")))
        let confirmed = expectation(description: "the follow-up rescan confirmed the removal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { confirmed.fulfill() }
        wait(for: [confirmed], timeout: 3)
        XCTAssertNil(model.note(NoteID("a")))
    }
}
