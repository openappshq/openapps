import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// `Automation`: the one door `opennotes://` links and the Shortcuts
/// actions both go through, over a model on a temporary folder.
final class AutomationTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel() -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)
        return model
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - new

    @MainActor func testNewCreatesTheFileWithFrontMatterAndSlidesItOut() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        var opened: [NoteID] = []
        automation.openNote = { opened.append($0) }
        let outcome = try automation.perform(.new(text: "Groceries\n- milk", title: nil, color: .sky))
        guard case .created(let id, let url) = outcome else { return XCTFail("expected .created") }
        XCTAssertEqual(id, NoteID("groceries"))
        XCTAssertEqual(url, model.store.fileURL(for: id))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("color: sky"), contents)
        XCTAssertTrue(contents.hasSuffix("Groceries\n- milk"), contents)
        XCTAssertEqual(opened, [id])
        XCTAssertEqual(model.active.map(\.id), [id])
    }

    @MainActor func testNewWithATitleUsesItAsTheFirstLineAndTheSlug() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        let outcome = try automation.perform(.new(text: "milk, eggs", title: "Groceries", color: nil))
        guard case .created(let id, _) = outcome else { return XCTFail("expected .created") }
        XCTAssertEqual(id, NoteID("groceries"))
        XCTAssertEqual(model.body(of: id)?.text, "Groceries\nmilk, eggs")
    }

    @MainActor func testNewWithEmptyTextIsTheHotkeysEmptyNote() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        var newNoteCalled = false
        automation.newNote = { newNoteCalled = true }
        let outcome = try automation.perform(.new(text: "", title: nil, color: nil))
        XCTAssertEqual(outcome, .newNote)
        XCTAssertTrue(newNoteCalled)
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(model.active, [])
    }

    // MARK: - append

    @MainActor func testAppendToAnExistingNoteIsSavedImmediately() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        _ = try automation.perform(.new(text: "Groceries\n- milk", title: nil, color: nil))
        let outcome = try automation.perform(.append(title: "Groceries", text: "- eggs"))
        guard case .appended(let id) = outcome else { return XCTFail("expected .appended") }
        let contents = try String(contentsOf: model.store.fileURL(for: id), encoding: .utf8)
        XCTAssertTrue(contents.hasSuffix("- eggs"), contents)
    }

    @MainActor func testAppendToAMissingTitleCreatesTheNote() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        let outcome = try automation.perform(.append(title: "New One", text: "first line"))
        guard case .appended(let id) = outcome else { return XCTFail("expected .appended") }
        XCTAssertEqual(model.body(of: id)?.text, "New One\nfirst line")
    }

    // MARK: - text

    @MainActor func testTextReturnsTheNotesBody() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        _ = try automation.perform(.new(text: "Groceries\n- milk", title: nil, color: nil))
        let outcome = try automation.perform(.text(title: "Groceries"))
        XCTAssertEqual(outcome, .text("Groceries\n- milk"))
    }

    @MainActor func testTextForAMissingNoteThrowsNoSuchNote() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        XCTAssertThrowsError(try automation.perform(.text(title: "Nothing"))) { error in
            XCTAssertEqual(error as? Automation.Failure, .noSuchNote("Nothing"))
        }
    }

    // MARK: - open

    @MainActor func testOpenSlidesTheNoteOutAndReportsItsID() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        _ = try automation.perform(.new(text: "Groceries\n- milk", title: nil, color: nil))
        var opened: [NoteID] = []
        automation.openNote = { opened.append($0) }
        let outcome = try automation.perform(.open(title: "Groceries"))
        XCTAssertEqual(outcome, .opened(NoteID("groceries")))
        XCTAssertEqual(opened, [NoteID("groceries")])
    }

    @MainActor func testOpenMatchesAPrefixOrContainsQuery() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        _ = try automation.perform(.new(text: "Weekly Groceries", title: nil, color: nil))
        automation.openNote = { _ in }
        XCTAssertEqual(try automation.perform(.open(title: "Weekly")), .opened(NoteID("weekly-groceries")))
        XCTAssertEqual(try automation.perform(.open(title: "Groceries")), .opened(NoteID("weekly-groceries")))
    }

    @MainActor func testOpeningAnArchivedNoteShowsAllNotesInstead() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        automation.openNote = { _ in }
        _ = try automation.perform(.new(text: "Groceries", title: nil, color: nil))
        model.archive(NoteID("groceries"))
        var openedNote: NoteID?
        var showedAll = false
        automation.openNote = { openedNote = $0 }
        automation.showAllNotes = { showedAll = true }
        let outcome = try automation.perform(.open(title: "Groceries"))
        XCTAssertEqual(outcome, .opened(NoteID("groceries")))
        XCTAssertTrue(showedAll)
        XCTAssertNil(openedNote)
    }

    // MARK: - read-only

    @MainActor private func makeReadOnlyModel() -> AppModel {
        let model = makeModel()
        model.license.bind(access: { false }, restriction: { LicenseRestriction.trialEndedSample }, canBuy: true)
        return model
    }

    @MainActor func testReadOnlyPerformOfNewThrowsReadOnlyAndWritesNothing() throws {
        let model = makeReadOnlyModel()
        let automation = Automation(model: model)
        XCTAssertThrowsError(try automation.perform(.new(text: "x", title: nil, color: nil))) { error in
            XCTAssertEqual(error as? Automation.Failure, .readOnly(model.readOnlyNotice))
        }
        XCTAssertEqual(try files(), [])
    }

    @MainActor func testReadOnlyOpenLinkOfNewRefusesAndWritesNothing() throws {
        let model = makeReadOnlyModel()
        let automation = Automation(model: model)
        var refused: String?
        automation.refuse = { refused = $0 }
        automation.openLink(.new(text: "x", title: nil, color: nil))
        XCTAssertEqual(refused, model.readOnlyNotice)
        XCTAssertEqual(try files(), [])
    }

    @MainActor func testReadOnlyAppendIsRefused() throws {
        let model = makeReadOnlyModel()
        let automation = Automation(model: model)
        XCTAssertThrowsError(try automation.perform(.append(title: "New", text: "line"))) { error in
            XCTAssertEqual(error as? Automation.Failure, .readOnly(model.readOnlyNotice))
        }
        XCTAssertEqual(try files(), [])
    }

    @MainActor func testReadOnlyTextAndOpenStillWork() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        automation.openNote = { _ in }
        _ = try automation.perform(.new(text: "Groceries\n- milk", title: nil, color: nil))
        model.license.bind(access: { false }, restriction: { LicenseRestriction.trialEndedSample }, canBuy: true)
        XCTAssertEqual(try automation.perform(.text(title: "Groceries")), .text("Groceries\n- milk"))
        XCTAssertEqual(try automation.perform(.open(title: "Groceries")), .opened(NoteID("groceries")))
    }

    // MARK: - never touches the real notes folder

    @MainActor func testTheRealNotesFolderIsNeverCreated() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/OpenNotes", isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: real.path)
        let model = makeModel()
        let automation = Automation(model: model)
        automation.openNote = { _ in }
        automation.newNote = {}
        _ = try automation.perform(.new(text: "x", title: nil, color: nil))
        _ = try automation.perform(.new(text: "", title: nil, color: nil))
        if !existedBefore {
            XCTAssertFalse(FileManager.default.fileExists(atPath: real.path))
        }
    }

    // MARK: - The whole text or nothing; the bound

    @MainActor func testGetNoteTextNeverReturnsASummaryOrAPreview() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        // A body the store could not read back: the note stays, its text is
        // the summary, and the action refuses rather than hand that out.
        let big = "Big\n" + String(repeating: "line of text\n", count: 200)
        try Data(big.utf8).write(to: folder.appendingPathComponent("big.md"))
        // A budget just large enough for the minimum: the file is evicted
        // once another note needs the room.
        let store = NoteStore(folder: folder, bodyBudget: NoteStore.maximumFileSize)
        let tight = AppModel(preferences: model.preferences, license: LicenseStatus(startsRestricted: false), store: store, watcher: FolderWatcher())
        tight.store.load(create: false)
        XCTAssertEqual(try Automation(model: tight).perform(.text(title: "Big")), .text(big))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("big.md"))
        // Evict by hand: a rescan forgets the file; a summary-only note would
        // be the case where the read fails. Simulate through a note whose
        // file is over the size limit: shown in part, never returned.
        let oversized = "Huge\n" + String(repeating: "0123456789", count: NoteStore.maximumFileSize / 10 + 1)
        try Data(oversized.utf8).write(to: folder.appendingPathComponent("huge.md"))
        model.store.rescan()
        XCTAssertEqual(model.note(NoteID("huge"))?.truncated, true)
        XCTAssertThrowsError(try automation.perform(.text(title: "Huge"))) { error in
            guard case Automation.Failure.storage(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("too large"), message)
        }
        XCTAssertThrowsError(try automation.perform(.append(title: "Huge", text: "more")))
    }

    @MainActor func testTextOverTheBoundIsRefusedWithWhy() throws {
        let model = makeModel()
        let automation = Automation(model: model)
        let longText = String(repeating: "a", count: AutomationLink.textLimit + 1)
        XCTAssertThrowsError(try automation.perform(.new(text: longText, title: nil, color: nil))) { error in
            XCTAssertEqual(error as? Automation.Failure, .tooLong)
        }
        XCTAssertEqual(try files(), [])
        var refused: [String] = []
        automation.refuse = { refused.append($0) }
        automation.openLink(.new(text: longText, title: nil, color: nil))
        XCTAssertEqual(refused, [], "a link over the bound is dropped, not refused as read-only")
        XCTAssertEqual(try files(), [])
    }
}
