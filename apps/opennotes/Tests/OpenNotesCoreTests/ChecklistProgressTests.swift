import XCTest
@testable import OpenNotesCore

/// "Checklist progress" (design/products/opennotes.md, "The deck"): the
/// count on a note's tab, from the same parse the styler and the click
/// use — nested items count, `[X]` is done, a `[ ]` that is no box (inside
/// a code span, after no list marker) is not counted.
final class ChecklistProgressTests: XCTestCase {
    @MainActor func testNoBoxesIsNil() {
        XCTAssertNil(MarkdownLite.checklistProgress(in: "Todo\nplain text\nno boxes here"))
        XCTAssertNil(MarkdownLite.checklistProgress(in: ""))
    }

    @MainActor func testAMixOfOpenAndDoneBoxes() {
        let progress = MarkdownLite.checklistProgress(in: "- [ ] milk\n- [x] eggs\n- [ ] bread")
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total, 3)
    }

    @MainActor func testNestedItemsCount() {
        let progress = MarkdownLite.checklistProgress(in: "- [ ] a\n  - [ ] b\n  - [x] c")
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total, 3)
    }

    @MainActor func testUppercaseXCountsAsDone() {
        let progress = MarkdownLite.checklistProgress(in: "- [X] done")
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total, 1)
    }

    @MainActor func testABoxWithNoSpaceAfterIsNotABox() {
        let progress = MarkdownLite.checklistProgress(in: "- [ ] real\n- [ ]x")
        XCTAssertEqual(progress?.done, 0)
        XCTAssertEqual(progress?.total, 1, "the second line's `[ ]x` is not a box at all")
    }

    @MainActor func testABracketPairInsideACodeSpanOnAPlainLineIsNotCounted() {
        // No list marker before it, so it is never seen as a box, in or out of a code span.
        let progress = MarkdownLite.checklistProgress(in: "- [ ] real\nplain `[ ]` line")
        XCTAssertEqual(progress?.done, 0)
        XCTAssertEqual(progress?.total, 1)
    }

    @MainActor func testAWholeLineInBackticksWithNoLeadingMarkerIsNotCounted() {
        let progress = MarkdownLite.checklistProgress(in: "- [ ] real\n`- [ ] x`")
        XCTAssertEqual(progress?.done, 0)
        XCTAssertEqual(progress?.total, 1, "the backtick, not a list marker, starts the line")
    }

    @MainActor func testStarPlusAndNumberedMarkersCount() {
        let progress = MarkdownLite.checklistProgress(in: "* [ ] a\n+ [ ] b\n1. [x] c")
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total, 3)
    }

    @MainActor func testIsCompleteOnlyWhenThereIsAtLeastOneBoxAndAllAreDone() {
        XCTAssertTrue(MarkdownLite.ChecklistProgress(done: 3, total: 3).isComplete)
        XCTAssertFalse(MarkdownLite.ChecklistProgress(done: 2, total: 3).isComplete)
        XCTAssertFalse(MarkdownLite.ChecklistProgress(done: 0, total: 0).isComplete, "no box at all is not complete")
    }

    @MainActor func testFractionAndLabel() {
        let progress = MarkdownLite.ChecklistProgress(done: 3, total: 7)
        XCTAssertEqual(progress.fraction, 3.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(progress.label, "3/7")
        XCTAssertEqual(MarkdownLite.ChecklistProgress(done: 0, total: 0).fraction, 0)
    }
}
