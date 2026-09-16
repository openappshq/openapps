import XCTest
@testable import OpenNotesCore

private final class MemoryFlags: FlagStore {
    var bools: [String: Bool] = [:]
    var ints: [String: Int] = [:]
    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func integer(forKey key: String) -> Int { ints[key] ?? 0 }
    func set(_ value: Bool, forKey key: String) { bools[key] = value }
    func set(_ value: Int, forKey key: String) { ints[key] = value }
    func removeObject(forKey key: String) { bools[key] = nil; ints[key] = nil }
    func hasValue(forKey key: String) -> Bool { bools[key] != nil || ints[key] != nil }
}

/// The app's own note (design/products/opennotes.md, "Notes"): a short
/// tour of exactly the Markdown the app understands and the gestures it
/// has, written once into an empty folder on a fresh install.
final class WelcomeNoteTests: XCTestCase {
    @MainActor func testTheFirstLineTitlesTheNote() {
        XCTAssertTrue(WelcomeNote.text.hasPrefix("Welcome to OpenNotes"))
        XCTAssertEqual(Note.title(of: WelcomeNote.text), "Welcome to OpenNotes")
    }

    @MainActor func testEveryMarkerTheDesignNamesRenders() {
        let runs = MarkdownLite.runs(in: WelcomeNote.text)
        XCTAssertTrue(runs.contains { $0.style.heading == 2 }, "a ## heading")
        XCTAssertTrue(runs.contains { $0.style.heading == 3 }, "a ### heading")
        XCTAssertTrue(runs.contains { $0.style.isBold })
        XCTAssertTrue(runs.contains { $0.style.isItalic })
        XCTAssertTrue(runs.contains { $0.style.isCode })
        XCTAssertTrue(runs.contains { $0.style.link != nil })
        XCTAssertTrue(runs.contains { $0.style.isListItem })
        XCTAssertTrue(runs.contains { $0.style.checkbox == false })
        XCTAssertTrue(runs.contains { $0.style.checkbox == true })
        XCTAssertTrue(runs.contains { $0.style.isChecked })
        let boxes = MarkdownLite.checkboxes(in: WelcomeNote.text)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes.map(\.checked), [false, true])
    }

    @MainActor func testTheTourNamesTheRealGesturesAndKeys() {
        for phrase in ["⌥⌘↑", "Drag a tab", "⌥⌘L", "Escape", "⌘-click", "⌘⇧M", "Serif", "thirteen papers", "iCloud Drive", "opennotes://new", "Append to Note"] {
            XCTAssertTrue(WelcomeNote.text.contains(phrase), phrase)
        }
    }

    /// The `=` line answers (the answer is drawn, never written), and the
    /// link line is one link the text view opens.
    @MainActor func testTheArithmeticLineAnswersAndTheLinkIsOne() {
        let answers = Arithmetic.answers(in: WelcomeNote.text, format: Arithmetic.Format(locale: Locale(identifier: "en_US")))
        XCTAssertEqual(answers.map(\.text), ["$285"])
        XCTAssertEqual(MarkdownLite.links(in: WelcomeNote.text).map(\.target), ["https://openapps.space/opennotes/"])
    }

    @MainActor func testTheNoteIsYellowUnpinnedAndOnTop() {
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let note = WelcomeNote.note(created: created)
        XCTAssertEqual(note.id, WelcomeNote.id)
        XCTAssertEqual(note.color, .yellow)
        XCTAssertEqual(note.typeface, .face(.sans))
        XCTAssertFalse(note.pinned)
        XCTAssertEqual(note.order, 0)
        XCTAssertEqual(note.created, created)
    }

    @MainActor func testTheNoteRoundTripsThroughFrontMatter() {
        let note = WelcomeNote.note(created: Date(timeIntervalSince1970: 1_789_000_000))
        let parsed = FrontMatter.parse(FrontMatter.serialize(note))
        XCTAssertEqual(parsed.color, .yellow)
        XCTAssertEqual(parsed.face, .sans)
        XCTAssertEqual(parsed.pinned, false)
        XCTAssertEqual(parsed.order, 0)
        XCTAssertTrue(parsed.hadFrontMatter)
        // The blank line serialize() puts after the block is the file's,
        // not the text's: parse drops it, so the pair round-trips.
        XCTAssertEqual(parsed.text, note.text)
    }

    @MainActor func testShouldCreateOnceForAnEmptyFolderThenNeverAgain() {
        let flags = MemoryFlags()
        XCTAssertTrue(WelcomeNote.shouldCreate(flags: flags, folderIsMissing: false, hasNotes: false))
        XCTAssertTrue(flags.bool(forKey: WelcomeNote.Key.decided))
        XCTAssertFalse(WelcomeNote.shouldCreate(flags: flags, folderIsMissing: false, hasNotes: false), "decided: never asked again")
    }

    @MainActor func testAFolderThatAlreadyHasNotesIsSomebodyElsesAndGetsNone() {
        let flags = MemoryFlags()
        XCTAssertFalse(WelcomeNote.shouldCreate(flags: flags, folderIsMissing: false, hasNotes: true))
        XCTAssertTrue(flags.bool(forKey: WelcomeNote.Key.decided), "decided all the same")
    }

    @MainActor func testAMissingFolderDecidesNothingAndAsksAgainNextTime() {
        let flags = MemoryFlags()
        XCTAssertFalse(WelcomeNote.shouldCreate(flags: flags, folderIsMissing: true, hasNotes: false))
        XCTAssertFalse(flags.bool(forKey: WelcomeNote.Key.decided))
        XCTAssertFalse(WelcomeNote.shouldCreate(flags: flags, folderIsMissing: true, hasNotes: false))
    }
}

/// `NoteStore.plant`: the app's own note, written whole and at once,
/// before licensing has answered.
final class NoteStorePlantTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-plant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @MainActor private func loadedStore() -> NoteStore {
        let store = NoteStore(folder: folder)
        store.load(create: false)
        return store
    }

    @MainActor func testPlantWritesTheNoteAndAnnouncesIt() throws {
        let store = loadedStore()
        var events: [StoreEvent] = []
        store.onEvent = { events.append($0) }
        try store.plant(WelcomeNote.note(created: Date(timeIntervalSince1970: 1_789_000_000)))
        XCTAssertEqual(try files(), ["welcome.md"])
        let contents = try String(contentsOf: folder.appendingPathComponent("welcome.md"), encoding: .utf8)
        let parsed = FrontMatter.parse(contents)
        XCTAssertEqual(parsed.color, .yellow)
        XCTAssertEqual(parsed.order, 0)
        XCTAssertEqual(store.active.map(\.id), [WelcomeNote.id])
        XCTAssertEqual(events, [.updated([WelcomeNote.id])])
    }

    @MainActor func testPlantingTwiceThrows() throws {
        let store = loadedStore()
        try store.plant(WelcomeNote.note(created: Date()))
        XCTAssertThrowsError(try store.plant(WelcomeNote.note(created: Date())))
    }

    @MainActor func testPlantingOverAFileAlreadyOnDiskThrowsAndDoesNotOverwrite() throws {
        try Data("Somebody else's welcome".utf8).write(to: folder.appendingPathComponent("welcome.md"))
        // Not loaded: this models the note landing on disk before the
        // store has read the folder at all.
        let store = NoteStore(folder: folder)
        XCTAssertThrowsError(try store.plant(WelcomeNote.note(created: Date())))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("welcome.md"), encoding: .utf8), "Somebody else's welcome")
    }

    @MainActor func testPlantIgnoresReadOnlyAccess() throws {
        let store = loadedStore()
        store.access = { false }
        XCTAssertTrue(store.readOnly)
        try store.plant(WelcomeNote.note(created: Date()))
        XCTAssertEqual(try files(), ["welcome.md"])
    }
}
