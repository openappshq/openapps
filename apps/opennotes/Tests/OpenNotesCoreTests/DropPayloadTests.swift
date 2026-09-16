import XCTest
@testable import OpenNotesCore

/// What a drop onto the deck becomes (design/products/opennotes.md, "Drop
/// to create"): the note's text, from the items the pasteboard carried.
final class DropPayloadTests: XCTestCase {
    @MainActor func testTextIsTheBodyExactlyAsDropped() {
        // Not a character changed: blank lines inside and at the end stay.
        XCTAssertEqual(DropPayload.noteText(for: [.text("hello\n\nworld\n\n\n")]), "hello\n\nworld\n\n\n")
        XCTAssertEqual(DropPayload.noteText(for: [.text("  indented\n")]), "  indented\n")
        XCTAssertEqual(DropPayload.noteText(for: [.text("one line")]), "one line")
    }

    @MainActor func testBlankOrWhitespaceOnlyTextIsNil() {
        XCTAssertNil(DropPayload.noteText(for: [.text("")]))
        XCTAssertNil(DropPayload.noteText(for: [.text("   \n  \n")]))
    }

    @MainActor func testAURLIsItsAddressOnOneLine() {
        let url = URL(string: "https://openapps.space/opennotes/")!
        XCTAssertEqual(DropPayload.noteText(for: [.url(url)]), "https://openapps.space/opennotes/")
    }

    @MainActor func testAFileIsAMarkdownLinkByName() {
        let file = URL(fileURLWithPath: "/Users/x/groceries.md")
        XCTAssertEqual(DropPayload.noteText(for: [.file(file)]), "[groceries.md](file:///Users/x/groceries.md)")
    }

    @MainActor func testAFileNameWithASpaceStaysPercentEncodedInTheURLButPlainInTheName() {
        let file = URL(fileURLWithPath: "/Users/x/My Notes.md")
        XCTAssertEqual(DropPayload.noteText(for: [.file(file)]), "[My Notes.md](file:///Users/x/My%20Notes.md)")
    }

    @MainActor func testMultipleItemsAreOneLineEachInOrder() {
        let items: [DropPayload.Item] = [
            .text("first"),
            .url(URL(string: "https://a.b")!),
            .file(URL(fileURLWithPath: "/tmp/note.md")),
        ]
        XCTAssertEqual(DropPayload.noteText(for: items), "first\nhttps://a.b\n[note.md](file:///tmp/note.md)")
    }

    @MainActor func testAnEmptyListIsNil() {
        XCTAssertNil(DropPayload.noteText(for: []))
    }

    @MainActor func testABlankItemAmongOthersIsSkippedNotAnEmptyLine() {
        let items: [DropPayload.Item] = [.text("   "), .text("kept")]
        XCTAssertEqual(DropPayload.noteText(for: items), "kept")
    }
}
