import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// P1 (app-review-2): auto-archive's next wake only used to recompute at
/// start, on a setting change, or from its own already-armed timer — never
/// when a note appeared or changed in an otherwise-empty (or already
/// caught-up) vault, so a note that fell due afterward never got an armed
/// timer. `scheduleAutoArchive(runNow: false)` on `.reloaded`/`.updated`
/// (`AppModel.handle`) is the fix. The timer itself is a private `Timer`
/// with no test seam, so what's asserted here is the deterministic half:
/// that a note picked up after `start()` is correctly recognised as overdue
/// (`AutoArchive.nextDue` in the past), which is what the re-arm computes
/// from. See the report for the exact limit of this coverage.
final class AppModelFixRound2Tests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix2-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel() -> AppModel {
        // Not a first launch: an empty folder would otherwise get the
        // welcome note at `start()`, and this test wants the vault empty.
        temporary.defaults.set(true, forKey: WelcomeNote.Key.decided)
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        preferences.autoArchiveDays = 7
        return AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder) { [self] in clock }, watcher: FolderWatcher()) { [self] in clock }
    }

    @MainActor func testANoteThatFallsDueAfterStartIsRecognisedAsOverdue() throws {
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.active, [])
        XCTAssertNil(AutoArchive.nextDue(in: model.active, days: 7))

        let past = clock.addingTimeInterval(-8 * 86_400)
        let contents = """
        ---
        color: coral
        face: sans
        pinned: false
        archived: false
        order: 0
        created: \(FrontMatter.format(past))
        modified: \(FrontMatter.format(past))
        ---

        Old note
        """
        let url = folder.appendingPathComponent("old.md")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)

        model.store.rescan()

        let note = try XCTUnwrap(model.note(NoteID("old")))
        XCTAssertEqual(note.modified, past)
        let due = try XCTUnwrap(AutoArchive.nextDue(in: model.active, days: 7))
        XCTAssertLessThan(due, clock, "a note modified 8 days ago with a 7-day policy must already be due")
    }
}
