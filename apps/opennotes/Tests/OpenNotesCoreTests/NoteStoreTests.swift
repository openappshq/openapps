import XCTest
@testable import OpenNotesCore

/// The folder store against a temporary directory: reads, writes,
/// outside edits, conflicts, the provisional name, archive, reorder.
final class NoteStoreTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)
    private var events: [StoreEvent] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor private func makeStore(create: Bool = true) -> NoteStore {
        let store = NoteStore(folder: folder) { [self] in clock }
        store.onEvent = { [self] in events.append($0) }
        store.load(create: create)
        return store
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - Loading

    @MainActor func testLoadCreatesTheDefaultFolderAndReadsEveryMarkdownFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("groceries.md", "---\ncolor: mint\norder: 2\n---\n\nGroceries\n- milk\n")
        try write("plain.md", "Just text")
        try write("notes.txt", "not a note")
        try write("Archived.md", "---\narchived: true\n---\n\nOld\n")
        let store = makeStore()
        XCTAssertEqual(Set(store.notes.keys.map(\.rawValue)), ["groceries", "plain", "Archived"])
        XCTAssertEqual(store.note(NoteID("groceries"))?.color, .mint)
        XCTAssertEqual(store.note(NoteID("groceries"))?.text, "Groceries\n- milk\n")
        XCTAssertEqual(store.note(NoteID("plain"))?.text, "Just text")
        XCTAssertEqual(store.active.map(\.id.rawValue), ["plain", "groceries"])
        XCTAssertEqual(store.archived.map(\.id.rawValue), ["Archived"])
        XCTAssertEqual(events, [.reloaded])
        XCTAssertFalse(store.folderIsMissing)
    }

    @MainActor func testAChosenFolderThatIsMissingIsReportedNotCreated() throws {
        let store = makeStore(create: false)
        XCTAssertTrue(store.folderIsMissing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(events, [.folderMissing, .reloaded])
        XCTAssertThrowsError(try store.create(color: .coral, face: .sans)) { error in
            XCTAssertEqual(error as? StoreError, .folderMissing(folder))
        }
        // The folder appears (a volume mounts): the next rescan reads it.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        store.rescan()
        XCTAssertFalse(store.folderIsMissing)
        XCTAssertEqual(store.active.map(\.id.rawValue), ["a"])
    }

    // MARK: - Creating and saving

    @MainActor func testANewNoteIsNotWrittenUntilItHasText() throws {
        let store = makeStore()
        let note = try store.create(color: .sky, face: .mono)
        XCTAssertTrue(note.id.rawValue.hasPrefix("note-"))
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(try store.save(note.id), .notWritten)
        XCTAssertEqual(try files(), [])
        try store.setText("Groceries\n- milk", for: note.id)
        XCTAssertTrue(store.hasUnsavedChanges(note.id))
        XCTAssertEqual(try store.save(note.id), .saved)
        XCTAssertFalse(store.hasUnsavedChanges(note.id))
        XCTAssertEqual(try files(), [note.id.fileName])
        let contents = try read(note.id.fileName)
        XCTAssertTrue(contents.hasPrefix("---\ncolor: sky\nface: mono\n"))
        XCTAssertTrue(contents.hasSuffix("---\n\nGroceries\n- milk"))
        XCTAssertEqual(try store.save(note.id), .unchanged)
    }

    @MainActor func testNewNotesLandOnTopOfTheDeck() throws {
        let store = makeStore()
        let first = try store.create(color: .coral, face: .sans)
        clock.addTimeInterval(60)
        let second = try store.create(color: .coral, face: .sans)
        XCTAssertEqual(store.active.map(\.id), [second.id, first.id])
        XCTAssertLessThan(second.order, first.order)
    }

    @MainActor func testClosingANewNoteNamesItsFileFromTheTitle() throws {
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setText("Groceries for Sunday\n- milk", for: note.id)
        let final = try store.finishProvisional(note.id)
        XCTAssertEqual(final.rawValue, "groceries-for-sunday")
        XCTAssertEqual(try files(), ["groceries-for-sunday.md"])
        XCTAssertNil(store.note(note.id))
        XCTAssertEqual(store.note(final)?.text, "Groceries for Sunday\n- milk")
        XCTAssertTrue(events.contains(.renamed(from: note.id, to: final)))
        // Never renamed again, whatever the title becomes.
        try store.setText("Something else", for: final)
        try store.save(final)
        XCTAssertEqual(try store.finishProvisional(final), final)
        XCTAssertEqual(try files(), ["groceries-for-sunday.md"])
        // The rescan after our own write sees nothing new.
        events = []
        store.rescan()
        XCTAssertEqual(events, [])
    }

    @MainActor func testATakenTitleGetsACounter() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("groceries.md", "Groceries")
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setText("Groceries", for: note.id)
        XCTAssertEqual(try store.finishProvisional(note.id).rawValue, "groceries-2")
        XCTAssertEqual(try files(), ["groceries-2.md", "groceries.md"])
    }

    @MainActor func testAnUntitledNoteKeepsItsTimestampName() throws {
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setText("日本語のメモ", for: note.id)
        XCTAssertEqual(try store.finishProvisional(note.id), note.id)
        XCTAssertEqual(try files(), [note.id.fileName])
    }

    @MainActor func testAnEmptyNewNoteIsDiscardedWithItsProvisionalFile() throws {
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setText("x", for: note.id)
        try store.save(note.id)
        XCTAssertEqual(try files(), [note.id.fileName])
        try store.setText("  \n", for: note.id)
        XCTAssertTrue(store.discardIfEmpty(note.id))
        XCTAssertEqual(try files(), [])
        XCTAssertNil(store.note(note.id))
        XCTAssertTrue(events.contains(.removed([note.id])))
        // A note that has closed once is never discarded, empty or not.
        let kept = try store.create(color: .coral, face: .sans)
        try store.setText("keep", for: kept.id)
        let keptID = try store.finishProvisional(kept.id)
        try store.setText("", for: keptID)
        XCTAssertFalse(store.discardIfEmpty(keptID))
        try store.save(keptID)
        XCTAssertEqual(try files(), ["keep.md"])
    }

    @MainActor func testReadOnlyRefusesEveryChangeButNotReadingOrExporting() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        // The access is asked at every mutation, never stored.
        var allowed = false
        store.access = { allowed }
        XCTAssertTrue(store.readOnly)
        XCTAssertThrowsError(try store.create(color: .coral, face: .sans)) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertThrowsError(try store.setText("B", for: NoteID("a"))) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertThrowsError(try store.setColor(.mint, for: NoteID("a"))) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertThrowsError(try store.archive(NoteID("a"))) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertEqual(store.note(NoteID("a"))?.archived, false)
        XCTAssertThrowsError(try store.unarchive(NoteID("a"))) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertThrowsError(try store.reorder([NoteID("a")])) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertNoThrow(try store.export(NoteID("a"), as: .markdown))
        XCTAssertEqual(try read("a.md"), "A", "nothing written while read-only")
        store.rescan()
        XCTAssertEqual(store.note(NoteID("a"))?.text, "A")
        allowed = true
        XCTAssertFalse(store.readOnly)
        XCTAssertNoThrow(try store.archive(NoteID("a")))
        XCTAssertEqual(try read("a.md").contains("archived: true"), true)
    }

    /// The one exception to read-only: text `setText` accepted while access
    /// was on is written by `save`/`saveAll` whatever `access` says by the
    /// time the flush runs; a second, new edit made after access is
    /// withdrawn is refused like any other change.
    @MainActor func testAcceptedTextIsFlushedAfterAccessIsWithdrawnButANewEditIsRefused() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        var allowed = true
        store.access = { allowed }
        try store.setText("Typed while allowed", for: NoteID("a"))
        allowed = false
        XCTAssertNoThrow(try store.save(NoteID("a")))
        XCTAssertTrue(try read("a.md").contains("Typed while allowed"))
        XCTAssertFalse(store.hasUnsavedChanges(NoteID("a")))
        XCTAssertThrowsError(try store.setText("A second, refused edit", for: NoteID("a"))) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertEqual(store.note(NoteID("a"))?.text, "Typed while allowed", "the refused edit never reached the buffer")
    }

    /// A pending change that is not accepted text (a flag on a note with no
    /// file yet) has nowhere the license can carry it: `saveAll` finds it
    /// refused, skips it silently — not a failure, so quit is never held —
    /// and it stays dirty for the next flush that finds access restored.
    @MainActor func testAPendingNonTextChangeOnAnEmptyProvisionalNoteIsSkippedSilentlyWhileReadOnly() throws {
        let store = makeStore()
        var allowed = true
        store.access = { allowed }
        let note = try store.create(color: .coral, face: .sans)
        try store.setPinned(true, for: note.id)
        XCTAssertTrue(store.hasUnsavedChanges(note.id))
        allowed = false
        let problems = store.saveAll()
        XCTAssertEqual(problems, [:], "a refusal that is not accepted text is skipped silently, not reported")
        XCTAssertTrue(store.hasUnsavedChanges(note.id), "stays dirty for the next flush")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(note.id.fileName).path))
    }

    // MARK: - Outside edits

    @MainActor func testAnOutsideEditIsPickedUpByRescan() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        events = []
        // Same size, different content, a later date: the file changed.
        try write("a.md", "B")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: folder.appendingPathComponent("a.md").path)
        store.rescan()
        XCTAssertEqual(store.note(NoteID("a"))?.text, "B")
        XCTAssertEqual(events, [.updated([NoteID("a")])])
        // Touched without a change: nothing announced.
        events = []
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: folder.appendingPathComponent("a.md").path)
        store.rescan()
        XCTAssertEqual(events, [])
        // Added, and removed: the file gone is noted, and the note goes
        // only once a later rescan (after the grace) still finds no file.
        try write("b.md", "B note")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        store.rescan()
        XCTAssertEqual(events, [.updated([NoteID("b")])])
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertEqual(store.pendingRemovals, [NoteID("a")])
        clock += NoteStore.removalGrace
        store.rescan()
        XCTAssertEqual(events, [.updated([NoteID("b")]), .removed([NoteID("a")])])
        XCTAssertNil(store.note(NoteID("a")))
        XCTAssertEqual(store.pendingRemovals, [])
    }

    @MainActor func testAnOutsideEditUnderUnsavedChangesKeepsTheFileAndMovesOursToAConflictCopy() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try write("a.md", "Theirs, longer")
        store.rescan()
        // Theirs is not adopted while ours is unsaved.
        XCTAssertEqual(store.note(NoteID("a"))?.text, "Ours")
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(copy.rawValue.hasPrefix("a (conflict "), copy.rawValue)
        // The file keeps theirs; ours is the new note beside it.
        XCTAssertEqual(try read("a.md"), "Theirs, longer")
        XCTAssertTrue(try read(copy.fileName).hasSuffix("\n\nOurs"))
        XCTAssertEqual(store.note(NoteID("a"))?.text, "Theirs, longer")
        XCTAssertEqual(store.note(copy)?.text, "Ours")
        XCTAssertFalse(store.hasUnsavedChanges(copy))
        XCTAssertTrue(events.contains(.renamed(from: NoteID("a"), to: copy)))
        XCTAssertTrue(events.contains(.conflict(NoteID("a"), copy: store.fileURL(for: copy))))
        // Both are notes like any other on the next rescan.
        store.rescan()
        XCTAssertEqual(store.notes.count, 2)
        // Saving the copy again writes no third file.
        try store.setText("Ours again", for: copy)
        XCTAssertEqual(try store.save(copy), .saved)
        XCTAssertEqual(try files().count, 2)
    }

    @MainActor func testAFileRemovedUnderUnsavedChangesIsWrittenAgain() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        store.rescan()
        XCTAssertNotNil(store.note(NoteID("a")))
        XCTAssertEqual(try store.save(NoteID("a")), .saved)
        XCTAssertEqual(try files(), ["a.md"])
    }

    @MainActor func testTheFolderGoingAwayIsReportedOnSave() throws {
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setText("x", for: note.id)
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try store.save(note.id)) { XCTAssertEqual($0 as? StoreError, .folderMissing(folder)) }
        XCTAssertTrue(store.folderIsMissing)
        XCTAssertTrue(store.hasUnsavedChanges(note.id))
    }

    // MARK: - Properties

    @MainActor func testColorFacePinAndArchiveWriteAtOnce() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setColor(.lilac, for: NoteID("a"))
        try store.setFace(.mono, for: NoteID("a"))
        try store.setPinned(true, for: NoteID("a"))
        var contents = try read("a.md")
        XCTAssertTrue(contents.contains("color: lilac"))
        XCTAssertTrue(contents.contains("face: mono"))
        XCTAssertTrue(contents.contains("pinned: true"))
        XCTAssertTrue(contents.hasSuffix("\n\nA"))
        try store.archive(NoteID("a"))
        contents = try read("a.md")
        XCTAssertTrue(contents.contains("archived: true"))
        XCTAssertEqual(store.active, [])
        XCTAssertEqual(store.archived.map(\.id.rawValue), ["a"])
        try store.unarchive(NoteID("a"))
        XCTAssertEqual(store.active.map(\.id.rawValue), ["a"])
        XCTAssertFalse(store.hasUnsavedChanges(NoteID("a")))
    }

    @MainActor func testANewNoteKeepsColorChangesInMemoryUntilItHasText() throws {
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setColor(.mint, for: note.id)
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(store.note(note.id)?.color, .mint)
        try store.setText("Hello", for: note.id)
        try store.save(note.id)
        XCTAssertTrue(try read(note.id.fileName).contains("color: mint"))
    }

    @MainActor func testReorderRewritesOnlyTheNotesThatMoved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, name) in ["a", "b", "c"].enumerated() {
            try write("\(name).md", "---\norder: \(i)\n---\n\n\(name)")
        }
        try write("z.md", "---\narchived: true\norder: 0\n---\n\nz")
        let store = makeStore()
        XCTAssertEqual(store.active.map(\.id.rawValue), ["a", "b", "c"])
        events = []
        try store.reorder([NoteID("c"), NoteID("a"), NoteID("b"), NoteID("z")])
        XCTAssertEqual(store.active.map(\.id.rawValue), ["c", "a", "b"])
        XCTAssertEqual(events, [.updated([NoteID("c"), NoteID("a"), NoteID("b")])])
        XCTAssertTrue(try read("c.md").contains("order: 0"))
        XCTAssertTrue(try read("b.md").contains("order: 2"))
        XCTAssertTrue(try read("z.md").contains("order: 0"))
        events = []
        try store.reorder([NoteID("c"), NoteID("a"), NoteID("b")])
        XCTAssertEqual(events, [])
    }

    @MainActor func testExport() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "---\ncolor: mint\n---\n\n# Plan\n- [ ] **do** it\n")
        let store = makeStore()
        let md = try store.export(NoteID("a"), as: .markdown)
        XCTAssertEqual(md.name, "plan.md")
        XCTAssertEqual(String(decoding: md.data, as: UTF8.self), "# Plan\n- [ ] **do** it\n")
        let txt = try store.export(NoteID("a"), as: .plainText)
        XCTAssertEqual(txt.name, "plan.txt")
        XCTAssertEqual(String(decoding: txt.data, as: UTF8.self), "Plan\n- [ ] do it\n")
    }

    @MainActor func testSwitchingFoldersSavesFirstAndReadsTheOther() throws {
        let store = makeStore()
        let note = try store.create(color: .coral, face: .sans)
        try store.setText("Here", for: note.id)
        let other = folder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("Elsewhere".utf8).write(to: other.appendingPathComponent("e.md"))
        try store.switchFolder(to: other, create: false)
        XCTAssertEqual(store.folder, other)
        XCTAssertEqual(store.active.map(\.id.rawValue), ["e"])
        XCTAssertEqual(try files().filter { $0.hasSuffix(".md") }, [note.id.fileName])
    }

    @MainActor func testTheWatcherReportsAnOutsideWrite() throws {
        let store = makeStore()
        let watcher = FolderWatcher(latency: 0.1)
        let changed = expectation(description: "the folder changed")
        changed.assertForOverFulfill = false
        watcher.onChange = { changed.fulfill() }
        watcher.watch(folder)
        XCTAssertTrue(watcher.isWatching)
        try write("outside.md", "From another app")
        wait(for: [changed], timeout: 10)
        store.rescan()
        XCTAssertEqual(store.active.map(\.id.rawValue), ["outside"])
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }
}
