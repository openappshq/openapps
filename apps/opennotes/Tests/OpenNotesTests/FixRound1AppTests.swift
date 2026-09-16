import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// Regression tests for review 1's P0-4 (held flushes) at the model level:
/// a failed flush keeps the note dirty and says why, and the next
/// successful flush clears it. `NoteStore`'s half of P0-4 (`saveAll`,
/// `switchFolder`) is covered in `Tests/OpenNotesCoreTests/FixRound1Tests.swift`.
final class AppModelFixRound1Tests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix1-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel() -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, store: NoteStore(folder: folder) { [self] in clock }, watcher: FolderWatcher()) { [self] in clock }
        model.store.load(create: false)
        return model
    }

    /// `flush()` reports the problem and the footer says so; once the
    /// folder is back, the same call clears it. This is the model-level
    /// half of the review's finding that a failed flush was discarded
    /// silently on folder switch / quit.
    @MainActor func testFlushReportsAndClearsAFailure() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("pending text", for: note.id)
        try FileManager.default.removeItem(at: folder)
        let problems = model.flush()
        XCTAssertEqual(Array(problems.keys), [note.id])
        XCTAssertTrue(model.store.hasUnsavedChanges(note.id))
        let problem = try XCTUnwrap(model.saveProblem)
        XCTAssertTrue(problem.hasPrefix("Couldn\u{2019}t save"), problem)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cleared = model.flush()
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertNil(model.saveProblem)
        XCTAssertFalse(model.store.hasUnsavedChanges(note.id))
    }
}
