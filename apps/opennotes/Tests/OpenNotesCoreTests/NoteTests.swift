import XCTest
@testable import OpenNotesCore

/// The note's derived facts and the file format.
final class NoteTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)

    @MainActor func testTitleIsTheFirstNonEmptyLineWithoutItsHeadingMarker() {
        XCTAssertEqual(Note.title(of: "Groceries\n- milk"), "Groceries")
        XCTAssertEqual(Note.title(of: "\n\n  # Standup 16 Sep  \nnotes"), "Standup 16 Sep")
        XCTAssertEqual(Note.title(of: "### Deep"), "Deep")
        XCTAssertEqual(Note.title(of: ""), "Untitled")
        XCTAssertEqual(Note.title(of: "   \n\t\n"), "Untitled")
        XCTAssertEqual(Note.title(of: "#"), "Untitled")
    }

    @MainActor func testPreviewSkipsTheTitleAndJoinsTheRest() {
        let note = Note(id: NoteID("g"), text: "Groceries\n\n- milk \n- eggs\n", created: date)
        XCTAssertEqual(note.preview, "- milk · - eggs")
        XCTAssertEqual(Note(id: NoteID("t"), text: "Only a title", created: date).preview, "")
    }

    @MainActor func testDeckOrderPutsPinnedFirstThenOrderThenNewest() {
        let a = Note(id: NoteID("a"), order: 2, created: date)
        let b = Note(id: NoteID("b"), order: 1, created: date)
        let pinned = Note(id: NoteID("p"), pinned: true, order: 9, created: date)
        let newer = Note(id: NoteID("n"), order: 1, created: date.addingTimeInterval(60))
        let sorted = [a, b, pinned, newer].sorted(by: Note.deckOrder).map(\.id.rawValue)
        XCTAssertEqual(sorted, ["p", "n", "b", "a"])
    }

    // MARK: - Front matter

    @MainActor func testSerializeThenParseRoundTrips() {
        let note = Note(id: NoteID("g"), text: "Groceries\n- [ ] milk\n", color: .mint, face: .mono, pinned: true, archived: false, order: -3, created: date, modified: date.addingTimeInterval(5))
        let contents = FrontMatter.serialize(note)
        XCTAssertTrue(contents.hasPrefix("---\ncolor: mint\nface: mono\npinned: true\narchived: false\norder: -3\ncreated: 2026-"))
        XCTAssertTrue(contents.hasSuffix("---\n\nGroceries\n- [ ] milk\n"))
        let back = NoteStore.parse(id: note.id, contents: contents, fileDate: date, fallbackCreated: .distantPast)
        XCTAssertEqual(back, note)
    }

    @MainActor func testAnEmptyNoteRoundTrips() {
        let note = Note(id: NoteID("e"), text: "", created: date)
        let back = NoteStore.parse(id: note.id, contents: FrontMatter.serialize(note), fileDate: date, fallbackCreated: .distantPast)
        XCTAssertEqual(back.text, "")
    }

    @MainActor func testAFileWithoutFrontMatterIsAllText() {
        let parsed = FrontMatter.parse("Just a note\nwith two lines")
        XCTAssertFalse(parsed.hadFrontMatter)
        XCTAssertEqual(parsed.text, "Just a note\nwith two lines")
        XCTAssertTrue(parsed.isEmpty)
    }

    @MainActor func testForeignFrontMatterIsLeftAsText() {
        // An Obsidian file with its own keys and none of ours: nothing is consumed.
        let contents = "---\ntags: [home]\naliases: []\n---\nBody"
        let parsed = FrontMatter.parse(contents)
        XCTAssertFalse(parsed.hadFrontMatter)
        XCTAssertEqual(parsed.text, contents)
        let note = NoteStore.parse(id: NoteID("x"), contents: contents, fileDate: date, fallbackCreated: date)
        XCTAssertEqual(note.color, .coral)
        XCTAssertEqual(note.created, date)
        XCTAssertEqual(note.text, contents)
    }

    @MainActor func testOurKeysAmongForeignOnesAreReadAndTheRestIgnored() {
        let contents = "---\ntags: [home]\ncolor: \"sky\"\npinned: yes\norder: 4\n---\n\nBody\n"
        let parsed = FrontMatter.parse(contents)
        XCTAssertTrue(parsed.hadFrontMatter)
        XCTAssertEqual(parsed.color, .sky)
        XCTAssertEqual(parsed.pinned, true)
        XCTAssertEqual(parsed.order, 4)
        XCTAssertNil(parsed.face)
        let note = NoteStore.parse(id: NoteID("x"), contents: contents, fileDate: date, fallbackCreated: date)
        XCTAssertEqual(note.text, "Body\n")
    }

    @MainActor func testAnUnclosedBlockIsText() {
        let contents = "---\ncolor: mint\nno close"
        XCTAssertFalse(FrontMatter.parse(contents).hadFrontMatter)
        XCTAssertEqual(FrontMatter.parse(contents).text, contents)
    }

    @MainActor func testModifiedTakesTheFileDateWhenNewer() {
        let older = date
        let contents = FrontMatter.serialize(Note(id: NoteID("m"), text: "x", created: older, modified: older))
        let fileDate = older.addingTimeInterval(3600)
        XCTAssertEqual(NoteStore.parse(id: NoteID("m"), contents: contents, fileDate: fileDate, fallbackCreated: older).modified, fileDate)
        XCTAssertEqual(NoteStore.parse(id: NoteID("m"), contents: contents, fileDate: older.addingTimeInterval(-10), fallbackCreated: older).modified, older)
    }

    // MARK: - File names

    @MainActor func testSlugsAreLowercaseASCIIWithHyphens() {
        XCTAssertEqual(NoteFileName.slug("Groceries"), "groceries")
        XCTAssertEqual(NoteFileName.slug("  Standup — 16 Sep!  "), "standup-16-sep")
        XCTAssertEqual(NoteFileName.slug("Café à la crème"), "cafe-a-la-creme")
        XCTAssertEqual(NoteFileName.slug("日本語"), "")
        XCTAssertEqual(NoteFileName.slug("a/b\\c:d"), "a-b-c-d")
        XCTAssertLessThanOrEqual(NoteFileName.slug(String(repeating: "word ", count: 40)).count, NoteFileName.maximumLength)
        XCTAssertFalse(NoteFileName.slug(String(repeating: "abcde ", count: 20)).hasSuffix("-"))
    }

    @MainActor func testIDsAreUniqueAndFallBackToATimestamp() {
        let taken: Set<String> = ["groceries", "groceries-2"]
        XCTAssertEqual(NoteFileName.id(for: "Groceries", created: date) { taken.contains($0.rawValue) }.rawValue, "groceries-3")
        XCTAssertEqual(NoteFileName.id(for: "Groceries", created: date) { _ in false }.rawValue, "groceries")
        let untitled = NoteFileName.id(for: "", created: date) { _ in false }.rawValue
        XCTAssertTrue(untitled.hasPrefix("note-"), untitled)
        XCTAssertEqual(untitled.count, "note-20260916-1030".count)
        XCTAssertEqual(NoteFileName.id(for: "Untitled", created: date) { _ in false }.rawValue, untitled)
        XCTAssertEqual(NoteFileName.id(for: "日本語", created: date) { _ in false }.rawValue, untitled)
    }

    @MainActor func testConflictCopiesAreNamedBesideTheNote() {
        let name = NoteFileName.conflictName(for: NoteID("groceries"), at: date)
        XCTAssertTrue(name.hasPrefix("groceries (conflict 20"), name)
        XCTAssertTrue(name.hasSuffix(").md"), name)
    }
}
