import Foundation
import XCTest
@testable import OpenNotesCore

/// The final review's P0: a body the budget evicted must never be edited
/// from its summary. `NoteStore.setText` (and `change`, for pin/color/face)
/// now requires the body already in memory — `note.bodyIsLoaded` — and
/// throws `StoreError.bodyUnavailable` instead of reading the file back
/// itself; only `body(of:)` reads, and it retries on every call, so the
/// very next call after the disk comes back reloads the whole body.
final class LazyBodyUnavailableTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)
    private let marker = "UNIQUE LAST PARAGRAPH"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-lazybody-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// 900,000 bytes of `letter`, ending in a marker that survives any
    /// append so a later "tail" check proves the whole body round-tripped.
    private func content(_ letter: Character) -> String {
        String(repeating: String(letter), count: 900_000 - marker.utf8.count) + marker
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Mirrors `FixRound3Tests`' retention setup: two 900,000-byte notes
    /// over a 1,000,000-byte budget, so exactly one stays loaded and the
    /// other is a summary from the moment `load()` returns.
    @MainActor func testAnEvictedBodyIsNeverEditedFromItsSummaryThenReloadsAndEditsFineOnceTheFileIsBack() throws {
        let idA = NoteID("a"), idB = NoteID("b")
        let contentByID: [NoteID: String] = [idA: content("a"), idB: content("b")]
        try Data(contentByID[idA]!.utf8).write(to: folder.appendingPathComponent(idA.fileName))
        try Data(contentByID[idB]!.utf8).write(to: folder.appendingPathComponent(idB.fileName))
        let store = NoteStore(folder: folder, bodyBudget: 1_000_000) { [self] in clock }
        store.load(create: false)

        let unloadedID = try XCTUnwrap([idA, idB].first { store.note($0)?.bodyIsLoaded == false }, "one of the two must have been evicted to fit the 1,000,000-byte budget")
        let loadedID = unloadedID == idA ? idB : idA
        XCTAssertEqual(store.note(loadedID)?.bodyIsLoaded, true)
        let originalBytes = try Data(contentsOf: folder.appendingPathComponent(unloadedID.fileName))
        let listingBefore = try files()

        // Move the unloaded note's file away: the disk cannot give it back.
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-lazybody-away-\(UUID().uuidString).md")
        try FileManager.default.moveItem(at: folder.appendingPathComponent(unloadedID.fileName), to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let summaryNote = try XCTUnwrap(store.body(of: unloadedID))
        XCTAssertFalse(summaryNote.bodyIsLoaded)
        XCTAssertLessThanOrEqual(summaryNote.text.utf8.count, NoteStore.summarySize)
        XCTAssertTrue(contentByID[unloadedID]!.hasPrefix(summaryNote.text), "the summary is a true prefix, not something invented")

        XCTAssertThrowsError(try store.setText(summaryNote.text + "user keystroke", for: unloadedID)) {
            XCTAssertEqual($0 as? StoreError, .bodyUnavailable(unloadedID))
        }
        XCTAssertThrowsError(try store.setPinned(true, for: unloadedID)) {
            XCTAssertEqual($0 as? StoreError, .bodyUnavailable(unloadedID))
        }
        XCTAssertFalse(store.hasUnsavedChanges(unloadedID))
        XCTAssertEqual(try Data(contentsOf: elsewhere), originalBytes, "the away file is untouched")
        XCTAssertTrue(try String(contentsOf: elsewhere, encoding: .utf8).hasSuffix(marker))
        XCTAssertEqual(try files(), listingBefore.filter { $0 != unloadedID.fileName }, "no conflict copy, nothing else created while the file was away")

        // Moved back, but nothing re-checked the in-memory flag yet: the
        // edit still must not start from the summary.
        try FileManager.default.moveItem(at: elsewhere, to: folder.appendingPathComponent(unloadedID.fileName))
        XCTAssertThrowsError(try store.setText(summaryNote.text + "user keystroke", for: unloadedID)) {
            XCTAssertEqual($0 as? StoreError, .bodyUnavailable(unloadedID))
        }
        XCTAssertFalse(store.hasUnsavedChanges(unloadedID))

        // The retry-then-edit path: `body(of:)` reloads the whole thing, and
        // only then may it be edited.
        let reloaded = try XCTUnwrap(store.body(of: unloadedID))
        XCTAssertTrue(reloaded.bodyIsLoaded)
        XCTAssertEqual(reloaded.text, contentByID[unloadedID])
        try store.setText(reloaded.text + "user keystroke", for: unloadedID)
        XCTAssertEqual(try store.save(unloadedID), .saved)
        let written = try String(contentsOf: folder.appendingPathComponent(unloadedID.fileName), encoding: .utf8)
        XCTAssertTrue(written.hasSuffix(marker + "user keystroke"), "the tail survives the round trip")
        XCTAssertGreaterThan(written.utf8.count, 900_000, "the front matter plus the full body plus the keystroke")

        // `setPinned`, now that the body is back, succeeds (`change` reloads).
        try store.setPinned(true, for: unloadedID)
        XCTAssertEqual(store.note(unloadedID)?.pinned, true)
    }
}
