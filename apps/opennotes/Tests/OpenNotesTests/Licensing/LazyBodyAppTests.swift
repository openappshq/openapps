import Foundation
import XCTest
@testable import OpenNotes
import OpenNotesCore

/// The final review's P0 at the app's own outputs: an unloaded body is
/// shown in part, and the model — like the store beneath it — never lets
/// an edit start from the summary. XCTest, not Swift Testing: the debounce
/// is a real `Timer` on the main run loop, and only `XCTestCase.wait`
/// reliably spins it (the same reasoning as `ContinuationTests.swift`).
final class LazyBodyAppTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private let marker = "UNIQUE LAST PARAGRAPH"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-lazybody-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary?.remove()
        temporary = nil
    }

    private func content(_ letter: Character) -> String {
        String(repeating: String(letter), count: 900_000 - marker.utf8.count) + marker
    }

    /// `LicenseStatus(startsRestricted: false)`: nothing here is about
    /// licensing, only about the store's body budget through the model.
    @MainActor private func makeModel() -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let store = NoteStore(folder: folder, bodyBudget: 1_000_000)
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: store)
        model.store.load(create: false)
        return model
    }

    /// The rule `DeckPanelController` wires as `content.mayEdit`
    /// (DeckPanelController.swift): allowed only while writing is allowed
    /// and the open note's whole body is in memory and not truncated. No
    /// window is opened here — `DeckPanelController` needs one — so this
    /// reproduces the same predicate directly against the model, which is
    /// exactly what it reads.
    @MainActor private func mayEdit(_ model: AppModel, _ id: NoteID) -> Bool {
        guard !model.readOnly, let note = model.note(id) else { return false }
        return note.bodyIsLoaded && !note.truncated
    }

    @MainActor func testAnUnloadedBodyIsShownInPartAndNeverEditedThenReloadsAndEditsFineOnceTheFileIsBack() throws {
        let idA = NoteID("a"), idB = NoteID("b")
        let contentByID: [NoteID: String] = [idA: content("a"), idB: content("b")]
        try Data(contentByID[idA]!.utf8).write(to: folder.appendingPathComponent(idA.fileName))
        try Data(contentByID[idB]!.utf8).write(to: folder.appendingPathComponent(idB.fileName))
        let model = makeModel()

        // Two 900,000-byte notes over a 1,000,000-byte budget: one is a
        // summary from the moment the model starts.
        let unloadedID = try XCTUnwrap([idA, idB].first { model.note($0)?.bodyIsLoaded == false })
        let fileURL = folder.appendingPathComponent(unloadedID.fileName)

        // Move the file away: the disk cannot give the body back either.
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-lazybody-app-away-\(UUID().uuidString).md")
        try FileManager.default.moveItem(at: fileURL, to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let summary = try XCTUnwrap(model.body(of: unloadedID))
        XCTAssertFalse(summary.bodyIsLoaded)
        XCTAssertLessThanOrEqual(summary.text.utf8.count, NoteStore.summarySize)
        XCTAssertEqual(model.statusLine(for: unloadedID), "Can’t read this note right now; shown in part.")
        XCTAssertFalse(mayEdit(model, unloadedID), "the deck must treat this note as read-only while its body is a summary")

        model.setText("would replace the whole file with the summary", for: unloadedID)
        XCTAssertEqual(model.saveProblem, StoreError.bodyUnavailable(unloadedID).localizedDescription)
        XCTAssertFalse(model.store.hasUnsavedChanges(unloadedID))

        // No debounce was ever scheduled (the refusal is synchronous, inside
        // `setText`); waiting past its window confirms nothing lands anyway.
        let waited = expectation(description: "past any debounce window")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.saveDebounce + 0.2) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data(contentByID[unloadedID]!.utf8), "the away file is untouched")

        // The file is back: the very next read reloads the whole body.
        try FileManager.default.moveItem(at: elsewhere, to: fileURL)
        let reloaded = try XCTUnwrap(model.body(of: unloadedID))
        XCTAssertTrue(reloaded.bodyIsLoaded)
        XCTAssertEqual(reloaded.text, contentByID[unloadedID])
        XCTAssertTrue(mayEdit(model, unloadedID))

        // `setText` itself does not clear a stale `saveProblem` on success
        // (only a completed save does); the debounced save below is what
        // actually clears the one the refused edit above left behind.
        model.setText(reloaded.text + "user keystroke", for: unloadedID)
        let saved = expectation(description: "the debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.saveDebounce + 0.2) { saved.fulfill() }
        wait(for: [saved], timeout: 2)
        let written = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(written.hasSuffix(marker + "user keystroke"), "the tail survives the round trip")
        XCTAssertFalse(model.store.hasUnsavedChanges(unloadedID))
        XCTAssertNil(model.saveProblem)
    }
}
