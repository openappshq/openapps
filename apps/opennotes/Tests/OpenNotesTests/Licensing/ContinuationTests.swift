import AppKit
import XCTest
@testable import OpenNotes
import OpenNotesCore
import OpenAppsLicensing

/// Work started while allowed and finished after the trial ended, with no
/// tick, no timer and no re-render in between: a debounced save in flight,
/// a provisional note left open, a folder chosen from an open panel, the
/// text view's own edit gate, the undo toast. The real manager's
/// projection decides at every resumption. One exception carries across a
/// deadline on purpose: text already typed while it was allowed is stamped
/// `accepted` by `NoteStore.setText` and is written by its flush (the
/// debounce, a close, sleep, quit) whatever the license says by then — the
/// restriction is on new edits, archiving, renaming, the folder and every
/// other change, never on text already accepted.
///
/// XCTest, not Swift Testing (unlike the rest of this directory): the save
/// debounce is a real `Timer` on the main run loop
/// (`AppModel.setText`/`AppModel.saveDebounce`), and only `XCTestCase.wait`
/// actually spins that run loop long enough for it to fire. A Swift Testing
/// `Task.sleep` here would pass whether or not the timer ever ran, which is
/// not what "the debounce writes the accepted text after the deadline"
/// is supposed to prove.
@MainActor
final class ContinuationTests: XCTestCase {
    private var clock = FakeClock()
    private var trialStore: MemoryTrialStore!
    private var feed: SnapshotBox!
    private var folder: URL!
    private var license: LicenseStatus!
    private var temporary: TemporaryDefaults!

    override func setUpWithError() throws {
        clock = FakeClock()
        trialStore = MemoryTrialStore()
        feed = SnapshotBox()
        license = LicenseStatus()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-continuations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary?.remove()
        temporary = nil
    }

    /// The model over the fakes, its status bound to the manager's
    /// projection, `secondsLeft` of trial left.
    @MainActor private func attach(secondsLeft: TimeInterval = 60) async -> AppModel {
        trialStore.record = TrialRecord(startedAt: clock.now.addingTimeInterval(-(3 * FakeClock.day - secondsLeft)), lastSeenAt: clock.now, registered: true)
        let clock = self.clock
        let feed = self.feed!
        let manager = LicenseManager(
            appID: Licensing.appID, products: LicenseProducts(paid: [EnforcementTests.paid]), client: FakeClient(), store: MemoryStore(),
            journal: MemoryJournal(), trialStore: trialStore, registry: FakeRegistry(), device: FakeDevice(),
            trialTiming: Licensing.trialTiming, now: { clock.now }, uptime: { clock.uptime }
        )
        await manager.setOnChange { feed.snapshot = $0 }
        await manager.load()
        await manager.checkOnLaunch()
        let project: () -> LicenseState = { feed.snapshot.state(now: clock.now, uptime: clock.uptime) }
        license.bind(
            access: { project().isFeatureEnabled }, state: { project() },
            restriction: { LicenseRestriction.card(for: project()) },
            badge: { LicenseBadge.label(for: project(), appName: Licensing.appName) }, canBuy: true
        )
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: license, store: NoteStore(folder: folder) { clock.now }, watcher: FolderWatcher()) { clock.now }
        model.store.load(create: false)
        XCTAssertTrue(license.hasAccess())
        return model
    }

    /// The one thing a deadline never takes: text already typed while it was
    /// allowed. `setText` stamps the buffer `accepted` the moment it lands,
    /// so its flush — the debounce, a close, sleep or quit — is written
    /// whatever the license says by the time it runs.
    @MainActor func testADebouncedSaveCrossesTheDeadlineAndStillWritesTheAcceptedText() async throws {
        let model = await attach()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Groceries", for: note.id)
        clock.advance(120) // the trial ends before the debounce fires
        let fired = expectation(description: "debounce window passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.saveDebounce + 0.2) { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.store.fileURL(for: note.id).path), "typed under access: the debounce's flush is never refused")
        XCTAssertFalse(model.store.hasUnsavedChanges(note.id))
        XCTAssertNil(model.saveProblem)
        XCTAssertEqual(model.statusLine(for: note.id), model.readOnlyNotice, "read-only for everything else")
    }

    @MainActor func testAProvisionalNoteClosedAfterTheDeadlineWritesTheAcceptedTextButKeepsItsProvisionalName() async throws {
        let model = await attach()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Trip ideas", for: note.id)
        clock.advance(120)
        let closed = model.closeNote(note.id)
        XCTAssertEqual(closed, note.id, "the accepted text is written, but finishProvisional's rename is a new file change, still refused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.store.fileURL(for: note.id).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [note.id.fileName])
        XCTAssertEqual(model.note(note.id)?.text, "Trip ideas")
    }

    @MainActor func testAFolderChosenWhileAllowedIsRefusedAfterTheDeadline() async throws {
        let model = await attach()
        XCTAssertTrue(model.mayChangeFolder())
        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-chosen-\(UUID().uuidString)", isDirectory: true)
        clock.advance(120)
        XCTAssertFalse(model.setFolder(chosen))
        XCTAssertEqual(model.preferences.folder, folder)
        XCTAssertFalse(model.useDefaultFolder())
    }

    @MainActor func testTheTextViewsOwnEditGateRefusesAKeystrokeTheInstantTheLicenseLapses() {
        let scrollView = NoteTextView.makeScrollableTextView()
        let textView = scrollView.documentView as! NoteTextView
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        var allowed = true
        textView.mayEdit = { allowed }
        textView.setText("a")
        XCTAssertEqual(textView.string, "a")
        allowed = false
        XCTAssertFalse(textView.shouldChangeText(in: NSRange(location: 1, length: 0), replacementString: "b"))
        XCTAssertEqual(textView.string, "a")
        allowed = true
        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: 1, length: 0), replacementString: "b"))
    }

    @MainActor func testTheUndoToastAfterTheDeadlineChangesNothing() async throws {
        let model = await attach()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Old shopping list", for: note.id)
        XCTAssertNotNil(model.save(note.id))
        model.archive(note.id)
        XCTAssertEqual(model.pendingUndo?.id, note.id)
        let bytesBefore = try? Data(contentsOf: model.store.fileURL(for: note.id))
        clock.advance(120)
        model.undoArchive()
        XCTAssertTrue(model.archived.map(\.id).contains(note.id))
        XCTAssertFalse(model.active.map(\.id).contains(note.id))
        XCTAssertEqual(try? Data(contentsOf: model.store.fileURL(for: note.id)), bytesBefore)
    }

    @MainActor func testTheSameWorkWithADayLeftCompletes() async throws {
        let model = await attach(secondsLeft: FakeClock.day)
        let note = try XCTUnwrap(model.createNote())
        model.setText("Finished before any deadline", for: note.id)
        XCTAssertNotNil(model.save(note.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.store.fileURL(for: note.id).path))
        let closed = try XCTUnwrap(model.closeNote(note.id))
        XCTAssertNotEqual(closed, note.id, "the provisional file took the title's name")
        model.archive(closed)
        XCTAssertTrue(model.archived.map(\.id).contains(closed))
    }
}
