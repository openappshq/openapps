import XCTest
@testable import OpenNotesCore

/// `ArchiveUndo`'s batches: a batch from All Notes' checked set is one
/// entry and one undo, on top of the deck's own single-note archive. Pure,
/// with an injected clock.
final class ArchiveUndoBatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    func testAnArchivedBatchIsOneEntryForAllTheIDsInOrder() {
        var undo = ArchiveUndo()
        let ids = [NoteID("a"), NoteID("b"), NoteID("c")]
        undo.archived(ids, title: "Groceries", at: now)
        let pending = undo.undoPending(at: now)
        XCTAssertEqual(pending?.ids, ids)
        XCTAssertEqual(pending?.kind, .archived)
        XCTAssertEqual(pending?.count, 3)
        XCTAssertEqual(pending?.id, ids[0], "the first note is what a single archive's toast would name")
    }

    func testMessageNamesTheTitleForOneNoteAndTheCountForABatch() {
        var single = ArchiveUndo()
        single.archived([NoteID("a")], title: "Groceries", at: now)
        XCTAssertEqual(single.current(at: now)?.message, "Archived “Groceries”")
        var batch = ArchiveUndo()
        batch.archived([NoteID("a"), NoteID("b")], title: "Groceries", at: now)
        XCTAssertEqual(batch.current(at: now)?.message, "Archived 2 notes")
    }

    func testARestoredBatchCarriesTheRestoredKindAndItsOwnMessage() {
        var undo = ArchiveUndo()
        undo.restored([NoteID("a"), NoteID("b")], title: "Groceries", at: now)
        XCTAssertEqual(undo.current(at: now)?.kind, .restored)
        XCTAssertEqual(undo.current(at: now)?.message, "Restored 2 notes")
    }

    func testAnEmptyBatchRegistersNothing() {
        var undo = ArchiveUndo()
        undo.archived([], title: "Groceries", at: now)
        XCTAssertNil(undo.current(at: now))
    }

    func testForgetOneNoteFromABatchLeavesTheRestOfTheEntry() {
        var undo = ArchiveUndo()
        undo.archived([NoteID("a"), NoteID("b"), NoteID("c")], title: "A", at: now)
        undo.forget(NoteID("b"))
        XCTAssertEqual(undo.current(at: now)?.ids, [NoteID("a"), NoteID("c")])
    }

    func testForgettingEveryNoteInABatchDropsTheEmptiedEntry() {
        var undo = ArchiveUndo()
        undo.archived([NoteID("a"), NoteID("b")], title: "A", at: now)
        undo.forget([NoteID("a"), NoteID("b")])
        XCTAssertNil(undo.current(at: now))
    }

    func testUndoPendingReturnsAndRemovesTheLatestEntryWithinItsWindow() {
        var undo = ArchiveUndo()
        undo.archived([NoteID("a")], title: "A", at: now)
        undo.restored([NoteID("b")], title: "B", at: now)
        let pending = undo.undoPending(at: now)
        XCTAssertEqual(pending?.ids, [NoteID("b")])
        // The most recent entry, popped: not offered a second time.
        XCTAssertEqual(undo.undoPending(at: now)?.ids, [NoteID("a")])
        XCTAssertNil(undo.undoPending(at: now))
    }

    func testAnExpiredEntryIsNotReturned() {
        var undo = ArchiveUndo()
        undo.archived([NoteID("a")], title: "A", at: now)
        XCTAssertNil(undo.undoPending(at: now.addingTimeInterval(ArchiveUndo.window + 1)))
    }
}
