import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// `AllNotesSelection`: the checked set over the rows on view, pure —
/// toggle, ⇧-extend, ⌘A, and what a narrower list leaves behind.
final class AllNotesSelectionTests: XCTestCase {
    private let a = NoteID("a"), b = NoteID("b"), c = NoteID("c"), d = NoteID("d"), e = NoteID("e")
    private var visible: [NoteID] { [a, b, c, d, e] }

    // MARK: - toggle

    @MainActor func testToggleChecksAndMovesTheAnchorToWhereItLanded() {
        var selection = AllNotesSelection()
        selection.toggle(b)
        XCTAssertTrue(selection.contains(b))
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection.anchor, b)
        selection.toggle(d)
        XCTAssertEqual(selection.anchor, d)
        // A ⇧-click now ranges from d, the last toggle, not b.
        selection.extend(to: a, in: visible)
        XCTAssertEqual(selection.checked, Set([a, b, c, d]))
    }

    @MainActor func testTogglingAChekedRowUnchecksItButStillMovesTheAnchor() {
        var selection = AllNotesSelection()
        selection.toggle(b)
        selection.toggle(b)
        XCTAssertFalse(selection.contains(b))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.anchor, b, "the anchor follows the click even though it unchecked")
        selection.extend(to: d, in: visible)
        XCTAssertEqual(selection.checked, Set([b, c, d]))
    }

    // MARK: - extend

    @MainActor func testExtendChecksTheRangeInBothDirectionsAndNeverUnchecks() {
        var selection = AllNotesSelection()
        selection.toggle(c)
        selection.extend(to: a, in: visible)
        XCTAssertEqual(selection.checked, Set([a, b, c]))
        // A second ⇧-click from the same anchor, the other way: widens.
        selection.extend(to: e, in: visible)
        XCTAssertEqual(selection.checked, Set([a, b, c, d, e]))
        // A ⇧-click back toward the anchor draws a smaller range, but a
        // note once checked stays checked.
        selection.extend(to: c, in: visible)
        XCTAssertEqual(selection.checked, Set([a, b, c, d, e]))
    }

    @MainActor func testExtendWithNoAnchorIsAToggle() {
        var selection = AllNotesSelection()
        selection.extend(to: b, in: visible)
        XCTAssertEqual(selection.checked, [b])
        XCTAssertEqual(selection.anchor, b)
    }

    @MainActor func testExtendWhenTheAnchorHasLeftTheVisibleRowsIsAToggle() {
        var selection = AllNotesSelection()
        selection.toggle(a)
        // A narrower search drops the anchor's row from view; the anchor
        // itself is untouched on the selection until something re-sets it.
        let narrowed = [b, c, d, e]
        selection.extend(to: c, in: narrowed)
        XCTAssertEqual(selection.checked, Set([a, c]), "a toggle, not a range")
        XCTAssertEqual(selection.anchor, c)
    }

    // MARK: - checkAll / clear

    @MainActor func testCheckAllChecksEveryVisibleRowAndSetsTheAnchorOnlyFromNone() {
        var selection = AllNotesSelection()
        selection.checkAll(visible)
        XCTAssertEqual(selection.checked, Set(visible))
        XCTAssertEqual(selection.anchor, a)
    }

    @MainActor func testCheckAllKeepsAnExistingAnchor() {
        var selection = AllNotesSelection()
        selection.toggle(d)
        selection.checkAll(visible)
        XCTAssertEqual(selection.anchor, d)
    }

    @MainActor func testClearEmptiesTheCheckedSetAndTheAnchor() {
        var selection = AllNotesSelection()
        selection.checkAll(visible)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    // MARK: - keep

    @MainActor func testKeepPrunesToTheVisibleRowsAndDropsAVanishedAnchor() {
        var selection = AllNotesSelection()
        selection.toggle(a)
        selection.toggle(c)
        XCTAssertEqual(selection.checked, Set([a, c]))
        XCTAssertEqual(selection.anchor, c)
        // A narrower search: a leaves the list, c (the anchor) stays.
        selection.keep([b, c, d])
        XCTAssertEqual(selection.checked, [c])
        XCTAssertEqual(selection.anchor, c, "still on view")
        // Narrower again: c leaves too, and takes the anchor with it.
        selection.keep([b, d])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    // MARK: - ordered

    @MainActor func testOrderedFollowsListOrderNotTheOrderThingsWereChecked() {
        var selection = AllNotesSelection()
        selection.toggle(d)
        selection.toggle(a)
        selection.toggle(c)
        XCTAssertEqual(selection.ordered(in: visible), [a, c, d])
    }

    // MARK: - coverage

    @MainActor func testCoverageIsNoneSomeOrAll() {
        var selection = AllNotesSelection()
        XCTAssertEqual(selection.coverage(of: visible), .none)
        selection.toggle(a)
        XCTAssertEqual(selection.coverage(of: visible), .some)
        selection.checkAll(visible)
        XCTAssertEqual(selection.coverage(of: visible), .all)
    }
}
