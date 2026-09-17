import XCTest
@testable import OpenNotesCore

/// `NoteStore.trash`: Delete on an archived note, moved through the
/// `moveToTrash` seam — a fake here, never the system's real Trash.
final class TrashTests: XCTestCase {
    private var folder: URL!
    private var fakeTrash: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)
    private var events: [StoreEvent] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-trash-\(UUID().uuidString)", isDirectory: true)
        fakeTrash = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-trash-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: fakeTrash)
    }

    @MainActor private func makeStore() -> NoteStore {
        let store = NoteStore(folder: folder) { [self] in clock }
        store.onEvent = { [self] in events.append($0) }
        store.moveToTrash = { [fakeTrash = fakeTrash!] url in
            let destination = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        store.load(create: false)
        return store
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    // MARK: - The move

    @MainActor func testTrashMovesTheArchivedNotesFileThroughTheSeamAndForgetsTheNote() throws {
        try write("a.md", "---\narchived: true\n---\n\nA")
        let store = makeStore()
        events = []
        let destination = try store.trash(NoteID("a"))
        XCTAssertEqual(destination, fakeTrash.appendingPathComponent("a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.md").path))
        XCTAssertNil(store.note(NoteID("a")))
        XCTAssertEqual(events, [.removed([NoteID("a")])])
    }

    // MARK: - Refusals

    @MainActor func testTrashRefusesAnActiveNote() throws {
        try write("a.md", "A")
        let store = makeStore()
        XCTAssertThrowsError(try store.trash(NoteID("a"))) {
            XCTAssertEqual($0 as? StoreError, .notArchived(NoteID("a")))
        }
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.md").path))
    }

    @MainActor func testTrashRefusesWhileReadOnly() throws {
        try write("a.md", "---\narchived: true\n---\n\nA")
        let store = makeStore()
        store.access = { false }
        XCTAssertThrowsError(try store.trash(NoteID("a"))) {
            XCTAssertEqual($0 as? StoreError, .readOnly)
        }
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.md").path))
    }

    /// A placeholder not yet downloaded: the note is archived (kept from
    /// before the file was evicted), but there is nothing on this Mac to
    /// move — the same setup `ICloudDriveTests`' download tests use.
    @MainActor func testTrashRefusesAnArchivedPlaceholderNotYetDownloaded() throws {
        try write("a.md", "---\narchived: true\n---\n\nA")
        let store = makeStore()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        try write(".a.md.icloud", "placeholder")
        store.rescan()
        let note = try XCTUnwrap(store.note(NoteID("a")))
        XCTAssertTrue(note.isDownloading)
        XCTAssertTrue(note.archived)
        XCTAssertThrowsError(try store.trash(NoteID("a"))) {
            XCTAssertEqual($0 as? StoreError, .notDownloaded(NoteID("a")))
        }
        XCTAssertNotNil(store.note(NoteID("a")))
    }

    @MainActor func testASeamThatThrowsReportsIOAndLeavesTheNoteInPlace() throws {
        try write("a.md", "---\narchived: true\n---\n\nA")
        let store = makeStore()
        store.moveToTrash = { _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try store.trash(NoteID("a"))) {
            guard case .io = $0 as? StoreError else { return XCTFail("expected .io, got \($0)") }
        }
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.md").path))
    }

    @MainActor func testAFileAlreadyGoneIsForgottenWithoutThrowingOrCallingTheSeam() throws {
        try write("a.md", "---\narchived: true\n---\n\nA")
        let store = makeStore()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        var seamCalled = false
        store.moveToTrash = { url in
            seamCalled = true
            return nil
        }
        let destination = try store.trash(NoteID("a"))
        XCTAssertNil(destination)
        XCTAssertFalse(seamCalled, "no file to move: the seam is never asked")
        XCTAssertNil(store.note(NoteID("a")))
    }
}
