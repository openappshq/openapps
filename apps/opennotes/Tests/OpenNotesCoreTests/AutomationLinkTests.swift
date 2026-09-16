import XCTest
@testable import OpenNotesCore

/// `AutomationLink`: parsing `opennotes://` links into an `AutomationRequest`,
/// composing a new note's text, appending a line, and finding a note by title.
final class AutomationLinkTests: XCTestCase {
    private func request(_ string: String) -> AutomationRequest? {
        AutomationLink.request(from: URL(string: string)!)
    }

    // MARK: - new

    @MainActor func testNewWithTextTitleAndColor() {
        XCTAssertEqual(
            request("opennotes://new?text=Hello%20world&title=Hi&color=Mint"),
            .new(text: "Hello world", title: "Hi", color: .mint)
        )
    }

    @MainActor func testNewWithNoQueryIsEmpty() {
        XCTAssertEqual(request("opennotes://new"), .new(text: "", title: nil, color: nil))
    }

    @MainActor func testNewDecodesTextAndDropsAnUnknownColor() {
        XCTAssertEqual(
            request("opennotes://new?text=2%2B2%20%3D&color=nope"),
            .new(text: "2+2 =", title: nil, color: nil)
        )
    }

    @MainActor func testNewKeepsAPlusInTheText() {
        XCTAssertEqual(request("opennotes://new?text=a+b"), .new(text: "a+b", title: nil, color: nil))
    }

    // MARK: - open

    @MainActor func testOpenWithATitle() {
        XCTAssertEqual(request("opennotes://open?title=Groceries"), .open(title: "Groceries"))
    }

    @MainActor func testOpenWithNoOrBlankTitleIsNil() {
        XCTAssertNil(request("opennotes://open"))
        XCTAssertNil(request("opennotes://open?title=%20"))
    }

    // MARK: - append

    @MainActor func testAppendWithTitleAndText() {
        XCTAssertEqual(request("opennotes://append?title=T&text=line"), .append(title: "T", text: "line"))
    }

    @MainActor func testAppendWithoutTextOrBlankTextIsNil() {
        XCTAssertNil(request("opennotes://append?title=T"))
        XCTAssertNil(request("opennotes://append?title=T&text=%0A"))
    }

    // MARK: - unrecognised

    @MainActor func testUnrecognisedHostIsNil() {
        XCTAssertNil(request("opennotes://activate?key=x"))
        XCTAssertNil(request("opennotes://bogus"))
    }

    @MainActor func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(request("OPENNOTES://NEW?text=x"), .new(text: "x", title: nil, color: nil))
    }

    @MainActor func testAnotherSchemeIsNil() {
        XCTAssertNil(request("https://new"))
    }

    // MARK: - compose

    @MainActor func testComposeTitleAndText() {
        XCTAssertEqual(AutomationLink.compose(title: "T", text: "line"), "T\nline")
    }

    @MainActor func testComposeTitleOnly() {
        XCTAssertEqual(AutomationLink.compose(title: "T", text: ""), "T")
    }

    @MainActor func testComposeTextOnly() {
        XCTAssertEqual(AutomationLink.compose(title: nil, text: "line"), "line")
    }

    @MainActor func testComposeNeitherIsEmpty() {
        XCTAssertEqual(AutomationLink.compose(title: nil, text: ""), "")
    }

    // MARK: - appending

    @MainActor func testAppendingToEmptyText() {
        XCTAssertEqual(AutomationLink.appending("x", to: ""), "x")
    }

    @MainActor func testAppendingToTextWithoutATerminator() {
        XCTAssertEqual(AutomationLink.appending("x", to: "abc"), "abc\nx")
    }

    @MainActor func testAppendingToTextEndingInANewline() {
        XCTAssertEqual(AutomationLink.appending("x", to: "abc\n"), "abc\nx")
    }

    // MARK: - note(titled:in:)

    private func note(_ title: String, id: String) -> Note {
        Note(id: NoteID(id), text: title, created: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @MainActor func testExactMatchBeatsPrefixBeatsContains() {
        let notes = [
            note("Weekly Groceries", id: "a"),
            note("Groceries", id: "b"),
            note("Groceries List", id: "c"),
        ]
        XCTAssertEqual(AutomationLink.note(titled: "Groceries", in: notes)?.id, NoteID("b"))
    }

    @MainActor func testPrefixMatchWhenNoExactMatch() {
        let notes = [note("Something else", id: "a"), note("Groceries List", id: "b")]
        XCTAssertEqual(AutomationLink.note(titled: "Groceries", in: notes)?.id, NoteID("b"))
    }

    @MainActor func testContainsMatchWhenNoExactOrPrefixMatch() {
        let notes = [note("Weekly Groceries Run", id: "a")]
        XCTAssertEqual(AutomationLink.note(titled: "Groceries", in: notes)?.id, NoteID("a"))
    }

    @MainActor func testCaseAndDiacriticInsensitive() {
        let notes = [note("Grocéries", id: "a")]
        XCTAssertEqual(AutomationLink.note(titled: "groceries", in: notes)?.id, NoteID("a"))
    }

    @MainActor func testOrderIsRespected() {
        let notes = [note("Groceries", id: "first"), note("Groceries", id: "second")]
        XCTAssertEqual(AutomationLink.note(titled: "Groceries", in: notes)?.id, NoteID("first"))
    }

    @MainActor func testNoMatchIsNil() {
        XCTAssertNil(AutomationLink.note(titled: "Nothing like it", in: [note("Groceries", id: "a")]))
    }

    @MainActor func testBlankQueryIsNil() {
        XCTAssertNil(AutomationLink.note(titled: "   ", in: [note("Groceries", id: "a")]))
    }

    // MARK: - Bounds

    @MainActor func testTextAndTitleAreBoundedAtTheDoor() throws {
        let longText = String(repeating: "a", count: AutomationLink.textLimit + 1)
        let fitsText = String(repeating: "a", count: AutomationLink.textLimit)
        let longTitle = String(repeating: "t", count: AutomationLink.titleLimit + 1)
        func url(_ string: String) -> URL { URL(string: string)! }
        XCTAssertNil(AutomationLink.request(from: url("opennotes://new?text=\(longText)")))
        XCTAssertNotNil(AutomationLink.request(from: url("opennotes://new?text=\(fitsText)")))
        XCTAssertNil(AutomationLink.request(from: url("opennotes://new?title=\(longTitle)&text=x")))
        XCTAssertNil(AutomationLink.request(from: url("opennotes://append?title=\(longTitle)&text=x")))
        XCTAssertNil(AutomationLink.request(from: url("opennotes://append?title=t&text=\(longText)")))
        XCTAssertNil(AutomationLink.request(from: url("opennotes://open?title=\(longTitle)")))
        XCTAssertFalse(AutomationLink.isBounded(.text(title: longTitle)))
        XCTAssertTrue(AutomationLink.isBounded(.new(text: fitsText, title: nil, color: nil)))
    }
}
