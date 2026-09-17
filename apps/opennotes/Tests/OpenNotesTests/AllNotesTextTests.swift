import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// `AllNotesText`: the words the All Notes window derives from a note and a
/// state, pure and read without a window.
final class AllNotesTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    @MainActor private func note(pinned: Bool = false, archived: Bool = false, created: Date? = nil, modified: Date? = nil) -> Note {
        Note(id: NoteID("groceries"), text: "Groceries\nmilk", pinned: pinned, archived: archived, created: created ?? now, modified: modified ?? now)
    }

    // MARK: - count

    @MainActor func testCountIsNilForZeroAndPluralizesOtherwise() {
        XCTAssertNil(AllNotesText.count(0))
        XCTAssertEqual(AllNotesText.count(1), "1 note")
        XCTAssertEqual(AllNotesText.count(2), "2 notes")
        XCTAssertEqual(AllNotesText.count(30), "30 notes")
    }

    // MARK: - caption

    @MainActor func testCaptionIsArchivedEvenWhenPinned() {
        XCTAssertEqual(AllNotesText.caption(note(pinned: true, archived: true)), "ARCHIVED")
        XCTAssertEqual(AllNotesText.caption(note(archived: true)), "ARCHIVED")
    }

    @MainActor func testCaptionIsPinnedInTheDeckWhenPinnedAndNotArchived() {
        XCTAssertEqual(AllNotesText.caption(note(pinned: true)), "PINNED · IN THE DECK")
    }

    @MainActor func testCaptionIsActiveInTheDeckOtherwise() {
        XCTAssertEqual(AllNotesText.caption(note()), "ACTIVE · IN THE DECK")
    }

    // MARK: - edited

    @MainActor func testEditedJustNowUnderAMinute() {
        XCTAssertEqual(AllNotesText.edited(now.addingTimeInterval(-30), now: now), "Edited just now")
    }

    @MainActor func testEditedMinutesAgo() {
        XCTAssertEqual(AllNotesText.edited(now.addingTimeInterval(-5 * 60), now: now), "Edited 5 min ago")
    }

    @MainActor func testEditedHoursAgo() {
        XCTAssertEqual(AllNotesText.edited(now.addingTimeInterval(-3 * 3600), now: now), "Edited 3 h ago")
    }

    @MainActor func testEditedDaysAgo() {
        XCTAssertEqual(AllNotesText.edited(now.addingTimeInterval(-2 * 86_400), now: now), "Edited 2 d ago")
    }

    @MainActor func testEditedSevenOrMoreDaysAgoHasNoAgoSuffix() {
        let date = now.addingTimeInterval(-8 * 86_400)
        let expected = "Edited \(Age.text(date, now: now))"
        XCTAssertEqual(AllNotesText.edited(date, now: now), expected)
        XCTAssertFalse(AllNotesText.edited(date, now: now).hasSuffix("ago"))
    }

    // MARK: - footer

    @MainActor func testFooterJoinsCreatedEditedAndFileName() {
        var n = note(created: now.addingTimeInterval(-30 * 86_400), modified: now.addingTimeInterval(-5 * 60))
        n.truncated = false
        n.bodyIsLoaded = true
        let footer = AllNotesText.footer(n, now: now)
        XCTAssertTrue(footer.hasPrefix("Created "))
        XCTAssertTrue(footer.contains(AllNotesText.edited(n.modified, now: now)))
        XCTAssertTrue(footer.hasSuffix(n.id.fileName))
    }

    @MainActor func testFooterAppendsTruncatedNoticeWhenTruncated() {
        var n = note()
        n.truncated = true
        let footer = AllNotesText.footer(n, now: now)
        XCTAssertTrue(footer.hasSuffix("over 1 MB; shown from the start, read-only"))
    }

    @MainActor func testFooterAppendsUnreadableNoticeWhenBodyIsNotLoaded() {
        var n = note()
        n.bodyIsLoaded = false
        let footer = AllNotesText.footer(n, now: now)
        XCTAssertTrue(footer.hasSuffix("can’t read the file right now; shown in part"))
    }

    @MainActor func testFooterHasNoExtraPartWhenNothingIsWrong() {
        var n = note()
        n.truncated = false
        n.bodyIsLoaded = true
        let footer = AllNotesText.footer(n, now: now)
        XCTAssertTrue(footer.hasSuffix(n.id.fileName))
        XCTAssertFalse(footer.contains("shown in part"))
        XCTAssertFalse(footer.contains("read-only"))
    }

    // MARK: - empty

    @MainActor func testEmptyWithAQueryInTheDeck() {
        let result = AllNotesText.empty(query: "milk", archived: false)
        XCTAssertEqual(result.title, "No matches")
        XCTAssertEqual(result.detail, "Nothing in the deck contains “milk”.")
    }

    @MainActor func testEmptyWithAQueryInArchived() {
        let result = AllNotesText.empty(query: "milk", archived: true)
        XCTAssertEqual(result.title, "No matches")
        XCTAssertEqual(result.detail, "Nothing archived contains “milk”.")
    }

    @MainActor func testEmptyArchivedWithNoQuery() {
        let result = AllNotesText.empty(query: "", archived: true)
        XCTAssertEqual(result.title, "Nothing archived")
    }

    @MainActor func testEmptyDeckWithNoQuery() {
        let result = AllNotesText.empty(query: "", archived: false)
        XCTAssertEqual(result.title, "No notes yet")
    }

    // MARK: - rowLabel

    @MainActor func testRowLabelIncludesPinnedWhenPinned() {
        let n = note(pinned: true, modified: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(AllNotesText.rowLabel(n, now: now), "Groceries, pinned, 5 min")
    }

    @MainActor func testRowLabelOmitsPinnedWhenNotPinned() {
        let n = note(modified: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(AllNotesText.rowLabel(n, now: now), "Groceries, 5 min")
    }

    // MARK: - selected

    @MainActor func testSelectedNamesTheCountOfVisible() {
        XCTAssertEqual(AllNotesText.selected(3, of: 11), "3 of 11 selected")
        XCTAssertEqual(AllNotesText.selected(0, of: 11), "0 of 11 selected")
    }

    // MARK: - skipped / trashed

    @MainActor func testSkippedWithNoReasonsIsJustTheCount() {
        XCTAssertEqual(AllNotesText.skipped(2, of: 5, reasons: []), "2 of 5 skipped")
    }

    @MainActor func testSkippedJoinsEveryDistinctReason() {
        XCTAssertEqual(AllNotesText.skipped(2, of: 5, reasons: ["A", "B"]), "2 of 5 skipped: A · B")
    }

    @MainActor func testTrashedIsSingularForOneNote() {
        XCTAssertEqual(AllNotesText.trashed(1), "Moved 1 note to the Trash")
    }

    @MainActor func testTrashedIsPluralForMany() {
        XCTAssertEqual(AllNotesText.trashed(3), "Moved 3 notes to the Trash")
    }

    // MARK: - deleteTitle / deleteList

    @MainActor func testDeleteTitleForOneNoteNamesIt() {
        XCTAssertEqual(AllNotesText.deleteTitle(["Groceries"]), "Move “Groceries” to the Trash?")
    }

    @MainActor func testDeleteTitleForManyNamesTheCount() {
        XCTAssertEqual(AllNotesText.deleteTitle(["A", "B", "C"]), "Move 3 notes to the Trash?")
    }

    @MainActor func testDeleteListShowsEveryTitleUnderTheLimit() {
        let titles = ["A", "B", "C"]
        XCTAssertEqual(AllNotesText.deleteList(titles), titles)
    }

    @MainActor func testDeleteListCutsAtFiveAndSaysHowManyMore() {
        let titles = ["A", "B", "C", "D", "E", "F", "G"]
        XCTAssertEqual(AllNotesText.deleteList(titles), ["A", "B", "C", "D", "E", "and 2 more"])
    }

    // MARK: - rowLabel(checked:)

    @MainActor func testRowLabelIncludesCheckedWhenChecked() {
        let n = note(modified: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(AllNotesText.rowLabel(n, checked: true, now: now), "Groceries, 5 min, checked")
    }

    @MainActor func testRowLabelOmitsCheckedWhenNotChecked() {
        let n = note(modified: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(AllNotesText.rowLabel(n, now: now), "Groceries, 5 min")
    }

    // MARK: - AllNotesNotice.refusals / .expires

    @MainActor func testRefusalsIsNilWhenNothingWasSkipped() {
        var outcome = AppModel.BulkOutcome()
        outcome.done = [NoteID("a"), NoteID("b")]
        XCTAssertNil(AllNotesNotice.refusals(in: outcome))
    }

    @MainActor func testRefusalsDedupesReasonsAndCountsEveryAttempt() {
        var outcome = AppModel.BulkOutcome()
        outcome.done = [NoteID("a")]
        outcome.skipped = [
            .init(id: NoteID("b"), reason: "Too large"),
            .init(id: NoteID("c"), reason: "Too large"),
            .init(id: NoteID("d"), reason: "Read-only"),
        ]
        guard case .skipped(let count, let of, let reasons) = AllNotesNotice.refusals(in: outcome) else { return XCTFail("expected .skipped") }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(of, 4)
        XCTAssertEqual(reasons, ["Too large", "Read-only"])
    }

    @MainActor func testOnlyTheTrashedNoticeExpires() {
        XCTAssertTrue(AllNotesNotice.trashed(count: 2, urls: []).expires)
        XCTAssertFalse(AllNotesNotice.skipped(count: 1, of: 2, reasons: []).expires)
    }

    // MARK: - AllNotesExport.plan

    @MainActor func testPlanNumbersADuplicateNameWithinTheBatch() {
        let a = Note(id: NoteID("a"), text: "Groceries\nmilk", created: now)
        let b = Note(id: NoteID("b"), text: "Groceries\nmilk", created: now)
        let plans = AllNotesExport.plan([a, b], as: .markdown) { _ in false }
        XCTAssertEqual(plans.map(\.name), ["groceries.md", "groceries-2.md"])
        XCTAssertEqual(plans.map(\.id), [a.id, b.id])
    }

    @MainActor func testPlanAlsoAvoidsANameAlreadyTaken() {
        let a = Note(id: NoteID("a"), text: "Groceries\nmilk", created: now)
        let plans = AllNotesExport.plan([a], as: .plainText) { $0 == "groceries.txt" }
        XCTAssertEqual(plans.map(\.name), ["groceries-2.txt"])
    }

    // MARK: - AllNotesExport.write

    @MainActor func testWriteCreatesOneFilePerNoteAndNumbersAClashWithAnExistingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = Data("already here".utf8)
        try existing.write(to: folder.appendingPathComponent("groceries.md"))
        let a = Note(id: NoteID("a"), text: "Milk\nand eggs", created: now)
        let b = Note(id: NoteID("b"), text: "Bread\nrye", created: now)
        let c = Note(id: NoteID("c"), text: "Groceries\nmore", created: now)
        let outcome = AllNotesExport.write([a, b, c], as: .markdown, into: folder)
        XCTAssertEqual(outcome.done, [a.id, b.id, c.id])
        XCTAssertEqual(outcome.skipped, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["bread.md", "groceries-2.md", "groceries.md", "milk.md"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("milk.md")), Export.file(for: a, as: .markdown).data)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("bread.md")), Export.file(for: b, as: .markdown).data)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("groceries-2.md")), Export.file(for: c, as: .markdown).data)
        // The file already in the folder is untouched.
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("groceries.md")), existing)
    }

    @MainActor func testWriteSkipsEveryNoteWithAReasonWhenTheFolderDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-export-missing-\(UUID().uuidString)", isDirectory: true)
        let a = Note(id: NoteID("a"), text: "Groceries\nmilk", created: now)
        let outcome = AllNotesExport.write([a], as: .markdown, into: missing)
        XCTAssertEqual(outcome.done, [])
        XCTAssertEqual(outcome.skipped.map(\.id), [a.id])
        XCTAssertFalse(outcome.skipped[0].reason.isEmpty)
    }

    // MARK: - No defaults touched

    /// `DefaultsLeakGuardTests` (Tests/OpenNotesTests/TemporaryDefaults.swift)
    /// already checks the whole run for leaked `space.openapps.opennotes.*`
    /// files in `~/Library/Preferences`; these tests never touch
    /// `UserDefaults` at all, so no separate assertion is added here.
}
