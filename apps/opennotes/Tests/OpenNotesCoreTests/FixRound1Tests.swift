import XCTest
@testable import OpenNotesCore

/// Regression tests for review 1's seven P0s and the P1s fixed in
/// fc768e4 (app-review-1): the write transaction, safe provisional
/// cleanup, unique conflict names, held flushes, the order floor and
/// the memory/styling budgets. Each test reproduces the review's
/// verified probe against the store as it now behaves.
final class NoteStoreFixRound1Tests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)
    private var events: [StoreEvent] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix1-\(UUID().uuidString)", isDirectory: true)
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

    private func writeBytes(_ name: String, _ data: Data) throws {
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func readBytes(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func touch(_ name: String, by interval: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(interval)], ofItemAtPath: folder.appendingPathComponent(name).path)
    }

    // MARK: - P0-1: discardIfEmpty never destroys a replaced entry

    /// Mirrors the review's probe: create, save some text, clear it, then
    /// have another process replace the provisional file before Escape.
    /// This reproduces the finding at 398fa81, where `discardIfEmpty` only
    /// checked the in-memory text and deleted the path unconditionally; it
    /// fails whether or not a `rescan` ran in between, so both are covered
    /// here. Verified against the current NoteStore only (see report).
    @MainActor func testDiscardIfEmptyPreservesAnExternallyReplacedFileWithoutARescan() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("x", for: note.id)
        try store.save(note.id)
        XCTAssertEqual(try files(), [note.id.fileName])
        try store.setText("", for: note.id)
        try write(note.id.fileName, "foreign valuable")
        try touch(note.id.fileName, by: 30)
        XCTAssertFalse(store.discardIfEmpty(note.id))
        XCTAssertEqual(try read(note.id.fileName), "foreign valuable")
        XCTAssertEqual(store.note(note.id)?.text, "foreign valuable")
        XCTAssertFalse(store.hasUnsavedChanges(note.id))
    }

    @MainActor func testDiscardIfEmptyPreservesAnExternallyReplacedFileAfterARescan() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("x", for: note.id)
        try store.save(note.id)
        try store.setText("", for: note.id)
        try write(note.id.fileName, "foreign valuable")
        try touch(note.id.fileName, by: 30)
        // The note is dirty (emptied), so the rescan leaves it untouched;
        // the write transaction is what has to catch this, not the watcher.
        store.rescan()
        XCTAssertFalse(store.discardIfEmpty(note.id))
        XCTAssertEqual(try read(note.id.fileName), "foreign valuable")
        XCTAssertEqual(store.note(note.id)?.text, "foreign valuable")
    }

    /// The entry replaced by a directory before Escape: nothing is removed.
    @MainActor func testDiscardIfEmptyLeavesADirectoryThatReplacedTheFile() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("x", for: note.id)
        try store.save(note.id)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(note.id.fileName))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(note.id.fileName), withIntermediateDirectories: true)
        XCTAssertFalse(store.discardIfEmpty(note.id))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(note.id.fileName).path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The ordinary case is unchanged: a file holding exactly what the app
    /// wrote is removed and the note is gone.
    @MainActor func testDiscardIfEmptyStillRemovesItsOwnUntouchedFile() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("x", for: note.id)
        try store.save(note.id)
        try store.setText("", for: note.id)
        XCTAssertTrue(store.discardIfEmpty(note.id))
        XCTAssertEqual(try files(), [])
        XCTAssertNil(store.note(note.id))
    }

    // MARK: - P0-2: the write transaction

    /// The review's exact reproduction: load, set unsaved text, replace the
    /// file externally, save with NO rescan in between. At 398fa81 `write`
    /// only preserved an outside edit when a prior `rescan` had already
    /// populated `outsideEdits`, so this ordering silently overwrote the
    /// outside version; the fix compares the on-disk entry at write time.
    @MainActor func testSaveDetectsAnOutsideEditWithoutARescanFirst() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try write("a.md", "Theirs, longer")
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertEqual(try read("a.md"), "Theirs, longer")
        XCTAssertEqual(store.note(NoteID("a"))?.text, "Theirs, longer")
        XCTAssertEqual(store.note(copy)?.text, "Ours")
        let renamed = StoreEvent.renamed(from: NoteID("a"), to: copy)
        let conflict = StoreEvent.conflict(NoteID("a"), copy: store.fileURL(for: copy))
        guard let renamedIndex = events.firstIndex(of: renamed), let conflictIndex = events.firstIndex(of: conflict) else {
            return XCTFail("missing renamed/conflict events: \(events)")
        }
        XCTAssertLessThan(renamedIndex, conflictIndex)
    }

    /// Same size, later date, different bytes: the old stamp-only check
    /// (size + modification date) would have called this unchanged. The
    /// write transaction re-reads and hashes the content every time, so it
    /// still diverts.
    @MainActor func testSaveDivertsOnSameSizeSameEraDifferentContent() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "AAAA")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try write("a.md", "BBBB")
        try touch("a.md", by: 60)
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertEqual(try read("a.md"), "BBBB")
        XCTAssertEqual(store.note(copy)?.text, "Ours")
    }

    /// A metadata-only change (no text edit) still has to go through the
    /// write transaction: an unseen outside text edit is not lost just
    /// because the user only touched `pinned`.
    @MainActor func testMetadataOnlyChangeDivertsAnUnseenOutsideTextEdit() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try write("a.md", "Changed outside")
        events = []
        try store.setPinned(true, for: NoteID("a"))
        guard case .updated(let ids)? = events.first(where: { if case .updated(let ids) = $0 { return ids.count == 2 } else { return false } }),
              ids.first == NoteID("a") else {
            return XCTFail("expected .updated([a, copy]), got \(events)")
        }
        let copy = ids[1]
        XCTAssertEqual(try read("a.md"), "Changed outside")
        XCTAssertEqual(store.note(copy)?.pinned, true)
        XCTAssertEqual(store.note(copy)?.text, "A")
        XCTAssertEqual(store.note(NoteID("a"))?.text, "Changed outside")
    }

    /// A provisional note's first write races another process that has
    /// already taken its filename: ours moves to the next free provisional
    /// name instead of overwriting, and instead of throwing a "conflict"
    /// against a file we never owned.
    @MainActor func testProvisionalFirstWriteCollisionMovesToANewProvisionalName() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try write(note.id.fileName, "taken")
        try store.setText("Mine", for: note.id)
        let outcome = try store.save(note.id)
        guard case .keptAsConflictCopy(let newID) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertTrue(newID.rawValue.hasPrefix("note-"), newID.rawValue)
        XCTAssertNotEqual(newID, note.id)
        XCTAssertEqual(try read(note.id.fileName), "taken")
        XCTAssertEqual(store.note(note.id)?.text, "taken")
        XCTAssertEqual(store.note(newID)?.text, "Mine")
    }

    /// The entry replaced by a directory: refused outright, the note stays
    /// dirty, the directory is never touched.
    @MainActor func testSaveRefusesWhenTheEntryBecomesADirectory() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a.md"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save(NoteID("a"))) { error in
            XCTAssertEqual(error as? StoreError, .entryChanged(NoteID("a")))
        }
        XCTAssertTrue(store.hasUnsavedChanges(NoteID("a")))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.md").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// A non-UTF-8 replacement cannot be read back as text either; ours
    /// still goes beside it and the unreadable bytes are left exactly as
    /// they are.
    @MainActor func testSaveDivertsWhenTheReplacementIsNotUTF8() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours", for: NoteID("a"))
        let invalid = Data([0xFF, 0xFE, 0x00])
        try writeBytes("a.md", invalid)
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertEqual(try readBytes("a.md"), invalid)
        XCTAssertEqual(store.note(copy)?.text, "Ours")
    }

    // MARK: - P0-3: unique conflict names

    /// Two conflicts on the same note under one fixed clock (no calendar
    /// second boundary to rely on): the second must not overwrite the
    /// first's recovery copy.
    @MainActor func testTwoConflictsInTheSameSecondGetDistinctFiles() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        try store.setText("Ours1", for: NoteID("a"))
        try write("a.md", "Outside1")
        guard case .keptAsConflictCopy(let copy1) = try store.save(NoteID("a")) else { return XCTFail("expected first conflict") }
        try store.setText("Ours2", for: NoteID("a"))
        try write("a.md", "Outside2")
        guard case .keptAsConflictCopy(let copy2) = try store.save(NoteID("a")) else { return XCTFail("expected second conflict") }
        XCTAssertNotEqual(copy1, copy2)
        XCTAssertEqual(copy2.rawValue, copy1.rawValue + "-2")
        XCTAssertTrue(try read(copy1.fileName).hasSuffix("\n\nOurs1"))
        XCTAssertTrue(try read(copy2.fileName).hasSuffix("\n\nOurs2"))
        // The first copy is untouched by the second conflict.
        XCTAssertTrue(try read(copy1.fileName).hasSuffix("\n\nOurs1"))
        XCTAssertEqual(try files().filter { $0.contains("conflict") }.count, 2)
    }

    /// A foreign file already sitting at the exact generated conflict name
    /// is never overwritten; the reservation (`.withoutOverwriting`) moves
    /// on to `-2`.
    @MainActor func testAForeignFileAtTheConflictNameIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "A")
        let store = makeStore()
        let precious = NoteFileName.conflictName(for: NoteID("a"), at: clock)
        try write(precious, "precious")
        try store.setText("Ours", for: NoteID("a"))
        try write("a.md", "Outside")
        guard case .keptAsConflictCopy(let copy) = try store.save(NoteID("a")) else { return XCTFail("expected a conflict") }
        XCTAssertEqual(try read(precious), "precious")
        XCTAssertEqual(copy.fileName, NoteFileName.conflictStem(for: NoteID("a"), at: clock) + "-2.md")
        XCTAssertEqual(store.note(copy)?.text, "Ours")
    }

    // MARK: - P0-4: held flushes (see also FixRound1AppTests for the model's flush())

    /// `saveAll` reports every note it could not write, with why, and
    /// leaves them dirty.
    @MainActor func testSaveAllReportsFailuresAndKeepsNotesDirty() throws {
        let store = makeStore()
        let first = try store.create(color: .coral)
        try store.setText("one", for: first.id)
        clock.addTimeInterval(1)
        let second = try store.create(color: .coral)
        try store.setText("two", for: second.id)
        try FileManager.default.removeItem(at: folder)
        let problems = store.saveAll()
        XCTAssertEqual(Set(problems.keys), [first.id, second.id])
        XCTAssertTrue(store.hasUnsavedChanges(first.id))
        XCTAssertTrue(store.hasUnsavedChanges(second.id))
    }

    /// A folder switch is refused, with everything untouched, when the old
    /// folder cannot take the pending text; once it can, the switch goes
    /// through.
    @MainActor func testSwitchFolderIsRefusedWhenTheOldFolderCannotBeSaved() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("pending", for: note.id)
        let originalFolder = folder!
        try FileManager.default.removeItem(at: originalFolder)
        let other = originalFolder.deletingLastPathComponent().appendingPathComponent("opennotes-fix1-other-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try store.switchFolder(to: other, create: true)) { error in
            guard case StoreError.unsaved(let problems)? = error as? StoreError else { return XCTFail("expected .unsaved, got \(error)") }
            XCTAssertEqual(Array(problems.keys), [note.id])
        }
        XCTAssertEqual(store.folder, originalFolder)
        XCTAssertNotNil(store.note(note.id))
        XCTAssertTrue(store.hasUnsavedChanges(note.id))
        // The old folder comes back: the switch now succeeds.
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        XCTAssertNoThrow(try store.switchFolder(to: other, create: true))
        XCTAssertEqual(store.folder, other)
        try? FileManager.default.removeItem(at: other)
    }

    // MARK: - P0-5: the order floor never overflows

    /// Int.min/Int.max in hand-written front matter load clamped, and a
    /// new note can still be created (and lands first) without trapping.
    @MainActor func testExtremeOrdersLoadClampedAndANewNoteStillLandsOnTop() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("lo.md", "---\norder: -9223372036854775808\n---\n\nLo")
        try write("hi.md", "---\norder: 9223372036854775807\n---\n\nHi")
        let store = makeStore()
        XCTAssertEqual(store.note(NoteID("lo"))?.order, Note.orderRange.lowerBound)
        XCTAssertEqual(store.note(NoteID("hi"))?.order, Note.orderRange.upperBound)
        // No trap here is the assertion: create() used to do `lowest - 1`
        // unchecked, which overflows when lowest is already Int.min.
        let note = try store.create(color: .coral)
        XCTAssertEqual(store.active.first?.id, note.id)
        XCTAssertNoThrow(try store.reorder([note.id, NoteID("lo"), NoteID("hi")]))
        XCTAssertEqual(store.active.map(\.id.rawValue), [note.id.rawValue, "lo", "hi"])
    }

    @MainActor func testClampOrderBringsOutOfRangeValuesToTheEdge() {
        XCTAssertEqual(Note.clampOrder(Int.min), Note.orderRange.lowerBound)
        XCTAssertEqual(Note.clampOrder(Int.max), Note.orderRange.upperBound)
        XCTAssertEqual(Note.clampOrder(5), 5)
        XCTAssertEqual(Note.clampOrder(Note.orderRange.lowerBound), Note.orderRange.lowerBound)
        XCTAssertEqual(Note.clampOrder(Note.orderRange.upperBound), Note.orderRange.upperBound)
    }

    // MARK: - P0-6: memory and styling budgets

    /// A file over the budget is read only up to the truncated preview
    /// size, shown but refused for every kind of write, including
    /// metadata-only ones (`archive`).
    @MainActor func testOversizedFilesAreTruncatedAndRefuseEveryWrite() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let big = String(repeating: "a", count: NoteStore.maximumFileSize + 1)
        try write("big.md", big)
        let store = makeStore()
        let note = try XCTUnwrap(store.note(NoteID("big")))
        XCTAssertTrue(note.truncated)
        XCTAssertLessThanOrEqual(note.text.utf8.count, NoteStore.truncatedPreviewSize)
        XCTAssertThrowsError(try store.setText("changed", for: NoteID("big"))) { error in
            XCTAssertEqual(error as? StoreError, .oversized(NoteID("big")))
        }
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("big.md").path)[.size] as? Int
        XCTAssertEqual(try store.save(NoteID("big")), .unchanged)
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("big.md").path)[.size] as? Int
        XCTAssertEqual(sizeBefore, sizeAfter)
        XCTAssertThrowsError(try store.archive(NoteID("big"))) { error in
            XCTAssertEqual(error as? StoreError, .oversized(NoteID("big")))
        }
    }

    /// The truncated read has to cut somewhere; when that cut lands in the
    /// middle of a multi-byte character, decoding must not crash and must
    /// still produce a valid, budgeted string.
    @MainActor func testTruncationAtAMultibyteCharacterBoundaryDecodesSafely() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A leading single-byte character shifts every following 2-byte
        // "é" off the even boundary, so the 64,000-byte cut lands inside a
        // pair rather than between two of them.
        let text = "x" + String(repeating: "é", count: 700_000)
        try write("multibyte.md", text)
        let store = makeStore()
        let note = try XCTUnwrap(store.note(NoteID("multibyte")))
        XCTAssertTrue(note.truncated)
        XCTAssertFalse(note.text.isEmpty)
        XCTAssertLessThanOrEqual(note.text.utf8.count, NoteStore.truncatedPreviewSize)
    }
}

/// P0-6's styling half: the editor never allocates per-unit style state
/// past its budget, and `plainText` (export) still covers the whole text.
final class MarkdownLiteFixRound1Tests: XCTestCase {
    @MainActor func testStylingIsBoundedForAHugeChecklistButStillTilesTheText() {
        XCTAssertEqual(MarkdownLite.styleLimit, 64_000)
        let text = String(repeating: "- [ ] x\n", count: 100_000)
        let runs = MarkdownLite.runs(in: text, limit: 64_000)
        var expected = 0
        for run in runs {
            XCTAssertEqual(run.range.location, expected, "runs must be contiguous")
            XCTAssertGreaterThan(run.range.length, 0)
            expected = NSMaxRange(run.range)
        }
        XCTAssertEqual(expected, (text as NSString).length, "runs must cover the whole text")
        XCTAssertEqual(runs.last?.style, .plain)
        XCTAssertLessThan(runs.count, 64_000)
    }

    @MainActor func testPlainTextStripsMarkersPastTheStyleBudget() {
        // plainText uses limit: .max, so a marker far beyond styleLimit is
        // still recognised and stripped for export.
        let markedFarOut = String(repeating: "x", count: 70_000) + "**bold**"
        XCTAssertEqual(MarkdownLite.plainText(markedFarOut), String(repeating: "x", count: 70_000) + "bold")
    }
}

/// P0-7's non-timer half: how long until the next note is due, so the app
/// can wake once instead of polling. Days 0 (off) schedules nothing.
final class AutoArchiveFixRound1Tests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    @MainActor func testNextDueIsNilWhenOffAndTheEarliestDeadlineOtherwise() {
        let notes = [
            Note(id: NoteID("a"), text: "x", created: t0, modified: t0),
            Note(id: NoteID("pinned"), text: "x", pinned: true, created: t0, modified: t0.addingTimeInterval(-1_000_000)),
            Note(id: NoteID("b"), text: "x", created: t0, modified: t0.addingTimeInterval(-1000)),
        ]
        XCTAssertNil(AutoArchive.nextDue(in: notes, days: 0))
        let due = AutoArchive.nextDue(in: notes, days: 30)
        XCTAssertEqual(due, t0.addingTimeInterval(-1000).addingTimeInterval(30 * 86_400))
    }
}

/// P1: the deck's rules follow an identity that moved mid-session.
final class DeckStateMachineFixRound1Tests: XCTestCase {
    private let a = NoteID("a"), b = NoteID("b"), c = NoteID("c")

    @MainActor func testNoteRenamedUpdatesTheOpenNoteAndTheOrder() {
        var sut = DeckStateMachine(settings: DeckSettings(), notes: [a, b, c])
        _ = sut.handle(.openRequested(a))
        let x = NoteID("x")
        XCTAssertEqual(sut.handle(.noteRenamed(from: a, to: x)), [])
        XCTAssertEqual(sut.order, [x, b, c])
        XCTAssertEqual(sut.state, .open(x, editing: true))
    }

    @MainActor func testRenamingToAnIDAlreadyInTheOrderRemovesTheOldEntryInsteadOfDuplicating() {
        var sut = DeckStateMachine(settings: DeckSettings(), notes: [a, b, c])
        _ = sut.handle(.noteRenamed(from: a, to: b))
        XCTAssertEqual(sut.order, [b, c])
        XCTAssertEqual(sut.order.filter { $0 == b }.count, 1)
    }
}

/// P1: a full deck still fits a short screen — now by scrolling the fan,
/// with every tab listed and the ones past the fan's ends hidden by its
/// mask, the plus tab always inside the panel.
final class DeckGeometryFixRound1Tests: XCTestCase {
    @MainActor func testTwelveNotesFitAShortWideScreen() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let screen = CGRect(x: 0, y: 0, width: 800, height: 500)
        let layout = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        XCTAssertEqual(layout.tabs.count, 12)
        XCTAssertLessThanOrEqual(layout.panelFrame.height, 500)
        let bounds = CGRect(x: 0, y: 0, width: layout.panelFrame.width, height: layout.panelFrame.height)
        XCTAssertTrue(bounds.contains(layout.fan), "\(layout.fan) is outside \(bounds)")
        XCTAssertTrue(bounds.contains(layout.plusTab), "\(layout.plusTab) is outside \(bounds)")
        XCTAssertTrue(layout.canScrollDown)
        XCTAssertGreaterThan(layout.fan.height, 112, "at least one whole tab shows")
    }
}
