import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// The welcome note through the app (`AppModel.start`): planted once, on
/// the first launch into an empty folder, before the license has answered,
/// and never again — an upgrade, a folder switched later, an emptied
/// folder or an archived note all get none.
final class WelcomeNoteAppTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    /// Whether `~/Documents/OpenNotes` already existed before this test:
    /// nothing here may create it, checked again in `tearDown`.
    private var realFolderExistedBefore = false

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-welcome-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
        realFolderExistedBefore = MainActor.assumeIsolated { FileManager.default.fileExists(atPath: NoteStore.defaultFolder().path) }
    }

    override func tearDownWithError() throws {
        if !realFolderExistedBefore {
            let stillMissing = MainActor.assumeIsolated { !FileManager.default.fileExists(atPath: NoteStore.defaultFolder().path) }
            XCTAssertTrue(stillMissing, "must never create ~/Documents/OpenNotes")
        }
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel(license: LicenseStatus = LicenseStatus(startsRestricted: false)) -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        return AppModel(preferences: preferences, license: license, store: NoteStore(folder: folder), watcher: FolderWatcher())
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @MainActor func testAFreshInstallIntoAnEmptyFolderPlantsTheWelcomeNote() throws {
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.active.map(\.id), [WelcomeNote.id])
        XCTAssertEqual(try files(), ["welcome.md"])
        XCTAssertTrue(temporary.defaults.bool(forKey: WelcomeNote.Key.decided))
    }

    @MainActor func testASecondLaunchOverTheSameDefaultsPlantsNothingMore() throws {
        let first = makeModel()
        first.start()
        XCTAssertEqual(try files(), ["welcome.md"])
        // Emptied by hand between launches.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("welcome.md"))
        let second = makeModel()
        second.start()
        XCTAssertEqual(second.active, [])
        XCTAssertEqual(try files(), [])
    }

    @MainActor func testAFolderThatAlreadyHasANoteGetsNoWelcome() throws {
        try Data("Mine".utf8).write(to: folder.appendingPathComponent("mine.md"))
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.active.map(\.id.rawValue), ["mine"])
        XCTAssertTrue(temporary.defaults.bool(forKey: WelcomeNote.Key.decided), "decided all the same")
    }

    @MainActor func testEarlierPreferencesMeanNoWelcomeAndTheFlagStaysUnset() throws {
        // Evidence of an earlier launch, stored before `Preferences.init` runs.
        temporary.defaults.set("right", forKey: Preferences.Key.side)
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.active, [])
        XCTAssertEqual(try files(), [])
        XCTAssertFalse(temporary.defaults.hasValue(forKey: WelcomeNote.Key.decided))
    }

    @MainActor func testArchivingTheWelcomeNoteKeepsItGoneOnTheNextLaunch() throws {
        let first = makeModel()
        first.start()
        let id = try XCTUnwrap(first.active.first?.id)
        first.archive(id)
        XCTAssertEqual(first.active, [])
        let second = makeModel()
        second.start()
        XCTAssertEqual(second.active, [])
        XCTAssertEqual(second.archived.map(\.id), [WelcomeNote.id])
    }

    @MainActor func testPlantedEvenWhileTheLicenseStartsRestricted() throws {
        // The launch's first read: an official build's storage has not
        // answered yet, and a fresh install is in its trial regardless.
        let model = makeModel(license: LicenseStatus(startsRestricted: true))
        model.start()
        XCTAssertTrue(model.readOnly)
        XCTAssertEqual(model.active.map(\.id), [WelcomeNote.id])
        XCTAssertEqual(try files(), ["welcome.md"])
    }
}
