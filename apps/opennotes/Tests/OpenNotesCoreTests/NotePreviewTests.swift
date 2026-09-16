import XCTest
@testable import OpenNotesCore

/// `Note.preview`: the body as one line for the All Notes list.
final class NotePreviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)

    private func preview(_ text: String) -> String {
        Note(id: NoteID("n"), text: text, created: date).preview
    }

    @MainActor func testEmptyWhenOnlyATitle() {
        XCTAssertEqual(preview("Groceries"), "")
        XCTAssertEqual(preview("# Groceries"), "")
    }

    @MainActor func testBlankLinesAreSkipped() {
        XCTAssertEqual(preview("Title\n\n\nmilk\n\n\neggs\n\n"), "milk eggs")
    }

    @MainActor func testLinesAreJoinedWithASingleSpaceNotADot() {
        XCTAssertEqual(preview("Title\nmilk\neggs"), "milk eggs")
    }

    @MainActor func testHeadingBoldItalicAndCodeMarkersAreStripped() {
        XCTAssertEqual(preview("# Title\n## Section\n**bold** and _italic_ and `code`"), "Section bold and italic and code")
    }

    @MainActor func testListMarkersAreRemoved() {
        XCTAssertEqual(preview("Title\n- milk\n* eggs\n1. bread"), "milk eggs bread")
    }

    @MainActor func testCheckboxesAreRemoved() {
        XCTAssertEqual(preview("Title\n- [ ] milk\n- [x] eggs\n- [X] bread"), "milk eggs bread")
    }

    @MainActor func testABareCheckboxLineYieldsNothing() {
        XCTAssertEqual(preview("Title\n[ ]\nmilk"), "milk")
        XCTAssertEqual(preview("Title\n[ ]"), "")
    }

    @MainActor func testTitleLineIsNeverPartOfThePreviewEvenWithAHeadingMarker() {
        XCTAssertEqual(preview("# Groceries\nmilk"), "milk")
    }

    @MainActor func testOnlyTheFirstPreviewLengthCharactersOfTheBodyAreRead() {
        let filler = String(repeating: "b", count: 250)
        let text = "Title\nstart\n\(filler)\nexcluded"
        let result = preview(text)
        XCTAssertTrue(result.contains("start"))
        XCTAssertTrue(result.contains(filler))
        XCTAssertFalse(result.contains("excluded"))
    }

    @MainActor func testALinePast240CharactersDoesNotAppear() {
        let first = String(repeating: "a", count: 300)
        let text = "Title\n\(first)\nsecond line"
        let result = preview(text)
        XCTAssertEqual(result, first)
        XCTAssertFalse(result.contains("second line"))
    }
}
