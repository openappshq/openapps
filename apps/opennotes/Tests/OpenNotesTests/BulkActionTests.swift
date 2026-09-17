import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// `AppModel`'s bulk paths (All Notes' checked set): one file write per
/// note through the existing single-note path, one undo entry for the
/// whole batch, and a partial refusal that never touches the notes it
/// could not act on. Over a temporary folder; no window, no watcher.
final class BulkActionTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel(restricted: Bool = false) -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: restricted), store: NoteStore(folder: folder) { [self] in clock }, watcher: FolderWatcher()) { [self] in clock }
        model.store.load(create: false)
        return model
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - Archive / Restore

    @MainActor func testArchiveWritesEveryFileAndRegistersOneUndoForTheBatch() throws {
        try write("a.md", "A")
        try write("b.md", "B")
        try write("c.md", "C")
        let model = makeModel()
        let ids = [NoteID("a"), NoteID("b"), NoteID("c")]
        let outcome = model.archive(ids)
        XCTAssertEqual(outcome.done, ids)
        XCTAssertEqual(outcome.skipped, [])
        for name in ["a", "b", "c"] { XCTAssertTrue(try read("\(name).md").contains("archived: true")) }
        let pending = try XCTUnwrap(model.pendingUndo)
        XCTAssertEqual(pending.ids, ids)
        XCTAssertEqual(pending.kind, .archived)
        XCTAssertEqual(pending.message, "Archived 3 notes")
    }

    @MainActor func testUndoArchiveRestoresTheWholeBatch() throws {
        try write("a.md", "A")
        try write("b.md", "B")
        let model = makeModel()
        let ids = [NoteID("a"), NoteID("b")]
        model.archive(ids)
        model.undoArchive()
        XCTAssertEqual(model.active.map(\.id).sorted(), ids.sorted())
        XCTAssertEqual(model.archived, [])
    }

    @MainActor func testUnarchiveRegistersARestoredBatchWhoseOwnUndoArchivesItAgain() throws {
        try write("a.md", "---\narchived: true\n---\n\nA")
        try write("b.md", "---\narchived: true\n---\n\nB")
        let model = makeModel()
        let ids = [NoteID("a"), NoteID("b")]
        let outcome = model.unarchive(ids)
        XCTAssertEqual(outcome.done, ids)
        XCTAssertEqual(model.active.map(\.id).sorted(), ids.sorted())
        let pending = try XCTUnwrap(model.pendingUndo)
        XCTAssertEqual(pending.kind, .restored)
        model.undoArchive()
        XCTAssertEqual(model.active, [])
        XCTAssertEqual(model.archived.map(\.id).sorted(), ids.sorted())
    }

    @MainActor func testUndoArchiveIsRefusedWhileReadOnlyAndWorksAgainOnceAllowed() throws {
        try write("a.md", "A")
        let model = makeModel()
        model.archive([NoteID("a")])
        var allowed = false
        model.license.bind(access: { allowed }, restriction: { allowed ? nil : LicenseRestriction.trialEndedSample }, canBuy: true)
        model.undoArchive()
        XCTAssertEqual(model.archived.map(\.id), [NoteID("a")], "refused: still archived")
        allowed = true
        model.undoArchive()
        XCTAssertEqual(model.active.map(\.id), [NoteID("a")])
    }

    // MARK: - Pin / Colour / Font

    @MainActor func testSetPinnedColorTypefaceAndFontSizeWriteEveryFile() throws {
        try write("a.md", "A")
        try write("b.md", "B")
        let model = makeModel()
        let ids = [NoteID("a"), NoteID("b")]
        XCTAssertEqual(model.setPinned(true, for: ids).done, ids)
        XCTAssertTrue(try read("a.md").contains("pinned: true"))
        XCTAssertTrue(try read("b.md").contains("pinned: true"))
        XCTAssertEqual(model.setColor(.mint, for: ids).done, ids)
        XCTAssertTrue(try read("a.md").contains("color: mint"))
        XCTAssertTrue(try read("b.md").contains("color: mint"))
        XCTAssertEqual(model.setTypeface(.face(.mono), for: ids).done, ids)
        XCTAssertTrue(try read("a.md").contains("face: mono"))
        XCTAssertEqual(model.setFontSize(18, for: ids).done, ids)
        XCTAssertTrue(try read("a.md").contains("size: 18"))
        XCTAssertTrue(try read("b.md").contains("size: 18"))
    }

    // MARK: - Partial refusal

    @MainActor func testAnOversizedFileIsSkippedWithItsReasonWhileTheRestGoThrough() throws {
        try write("a.md", "A")
        let big = String(repeating: "a", count: NoteStore.maximumFileSize + 1)
        try write("big.md", big)
        let model = makeModel()
        let ids = [NoteID("a"), NoteID("big")]
        let outcome = model.setPinned(true, for: ids)
        XCTAssertEqual(outcome.done, [NoteID("a")])
        XCTAssertEqual(outcome.skipped.map(\.id), [NoteID("big")])
        XCTAssertEqual(outcome.skipped.first?.reason, StoreError.oversized(NoteID("big")).localizedDescription)
        XCTAssertEqual(outcome.attempted, 2)
        XCTAssertTrue(try read("a.md").contains("pinned: true"))
    }

    // MARK: - Read-only

    @MainActor func testReadOnlySkipsEveryNoteWithTheReadOnlyReasonAndWritesNothing() throws {
        try write("a.md", "A")
        try write("b.md", "B")
        let model = makeModel(restricted: true)
        let ids = [NoteID("a"), NoteID("b")]
        let outcome = model.archive(ids)
        XCTAssertEqual(outcome.done, [])
        XCTAssertEqual(outcome.skipped.map(\.id), ids)
        XCTAssertTrue(outcome.skipped.allSatisfy { $0.reason == StoreError.readOnly.localizedDescription })
        XCTAssertFalse(try read("a.md").contains("archived"))
        XCTAssertFalse(try read("b.md").contains("archived"))
        XCTAssertNil(model.pendingUndo)
    }

    // MARK: - Delete on archived notes (AppModel.trash)

    @MainActor func testTrashReportsTheURLsAndSkipsAnActiveNote() throws {
        try write("archived.md", "---\narchived: true\n---\n\nOld")
        try write("active.md", "Current")
        let model = makeModel()
        let fakeTrash = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-bulk-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeTrash) }
        model.store.moveToTrash = { url in
            let destination = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let ids = [NoteID("archived"), NoteID("active")]
        let outcome = model.trash(ids)
        XCTAssertEqual(outcome.done, [NoteID("archived")])
        XCTAssertEqual(outcome.trashed, [fakeTrash.appendingPathComponent("archived.md")])
        XCTAssertEqual(outcome.skipped.map(\.id), [NoteID("active")])
        XCTAssertEqual(outcome.skipped.first?.reason, StoreError.notArchived(NoteID("active")).localizedDescription)
        XCTAssertNil(model.note(NoteID("archived")))
        XCTAssertNotNil(model.note(NoteID("active")))
    }
}
