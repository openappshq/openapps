import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// A throwaway defaults suite under the temporary directory, removed at
/// the end, so no test touches ~/Library/Preferences.
final class TemporaryDefaults {
    let defaults: UserDefaults
    private let directory: URL
    private let suite: String

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = directory.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        defaults.removeSuite(named: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The model over a temporary folder: the debounce, closing, archive and
/// undo, the status line. No watcher is started, no window opened.
final class AppModelTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel() -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, store: NoteStore(folder: folder) { [self] in clock }, watcher: FolderWatcher()) { [self] in clock }
        model.store.load(create: false)
        return model
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @MainActor func testTypingIsWrittenAfterTheDebounceAndClosingNamesTheFile() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        XCTAssertEqual(note.color, .coral)
        XCTAssertEqual(note.face, .sans)
        model.setText("Groceries\n- milk", for: note.id)
        XCTAssertEqual(model.statusLine(for: note.id), "Editing…")
        XCTAssertEqual(try files(), [])
        let written = expectation(description: "written after the debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.saveDebounce + 0.2) { written.fulfill() }
        wait(for: [written], timeout: 2)
        XCTAssertEqual(try files(), [note.id.fileName])
        XCTAssertEqual(model.statusLine(for: note.id), "Saved · now")
        XCTAssertEqual(model.closeNote(note.id), NoteID("groceries"))
        XCTAssertEqual(try files(), ["groceries.md"])
        XCTAssertEqual(model.deckOrder, [NoteID("groceries")])
    }

    @MainActor func testAnEmptyNewNoteIsDroppedOnClose() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        XCTAssertNil(model.closeNote(note.id))
        XCTAssertEqual(model.active, [])
        XCTAssertEqual(try files(), [])
    }

    @MainActor func testArchiveOffersUndoForTenSeconds() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Call mum", for: note.id)
        let id = try XCTUnwrap(model.closeNote(note.id))
        model.archive(id)
        XCTAssertEqual(model.active, [])
        XCTAssertEqual(model.archived.map(\.id), [id])
        XCTAssertEqual(model.pendingUndo?.title, "Call mum")
        clock.addTimeInterval(5)
        model.undoArchive()
        XCTAssertEqual(model.active.map(\.id), [id])
        XCTAssertNil(model.pendingUndo)
        model.archive(id)
        clock.addTimeInterval(11)
        XCTAssertNil(model.pendingUndo)
        model.undoArchive()
        XCTAssertEqual(model.active, [])
        model.unarchive(id)
        XCTAssertEqual(model.active.map(\.id), [id])
    }

    @MainActor func testReadOnlyRefusesCreatingAndSaysSoInTheFooter() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("x", for: note.id)
        _ = model.closeNote(note.id)
        model.readOnly = true
        XCTAssertNil(model.createNote())
        XCTAssertTrue(model.store.readOnly)
        XCTAssertEqual(model.statusLine(for: NoteID("x")), model.readOnlyNotice)
        model.setText("changed", for: NoteID("x"))
        XCTAssertEqual(model.note(NoteID("x"))?.text, "x")
        model.archive(NoteID("x"))
        XCTAssertEqual(model.archived.count, 1)
    }

    @MainActor func testTheConflictNoticeShowsOnceAfterASaveOverAnOutsideEdit() throws {
        let model = makeModel()
        let url = folder.appendingPathComponent("a.md")
        try Data("A".utf8).write(to: url)
        model.store.load(create: false)
        model.setText("Ours", for: NoteID("a"))
        try Data("Theirs, longer".utf8).write(to: url)
        model.store.rescan()
        XCTAssertTrue(model.save(NoteID("a")))
        XCTAssertTrue(model.statusLine(for: NoteID("a")).hasPrefix("Saved over an outside edit"))
        model.clearConflictNotice()
        XCTAssertEqual(model.statusLine(for: NoteID("a")), "Saved · now")
        XCTAssertEqual(try files().count, 2)
    }

    @MainActor func testTheSaveProblemShowsUntilTheNextSuccess() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("x", for: note.id)
        try FileManager.default.removeItem(at: folder)
        XCTAssertFalse(model.save(note.id))
        XCTAssertTrue(model.statusLine(for: note.id).hasPrefix("Couldn’t save"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.store.rescan()
        XCTAssertTrue(model.save(note.id))
        XCTAssertEqual(model.statusLine(for: note.id), "Saved · now")
    }
}

/// The preferences round trip, the fresh-install evidence, the folder default.
final class PreferencesTests: XCTestCase {
    @MainActor func testDefaultsAndRoundTrip() {
        let temporary = TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(preferences.side, .right)
        XCTAssertEqual(preferences.display, .main)
        XCTAssertEqual(preferences.hotkey, .default)
        XCTAssertEqual(preferences.face, .sans)
        XCTAssertEqual(preferences.color, .coral)
        XCTAssertEqual(preferences.autoArchiveDays, 0)
        XCTAssertTrue(preferences.usesDefaultFolder)
        XCTAssertEqual(preferences.folder.lastPathComponent, "OpenNotes")
        preferences.side = .left
        preferences.display = .every
        preferences.hotkey = nil
        preferences.face = .mono
        preferences.color = .mint
        preferences.autoArchiveDays = 30
        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("chosen", isDirectory: true)
        preferences.folder = chosen
        let again = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(again.side, .left)
        XCTAssertEqual(again.display, .every)
        XCTAssertNil(again.hotkey)
        XCTAssertEqual(again.face, .mono)
        XCTAssertEqual(again.color, .mint)
        XCTAssertEqual(again.autoArchiveDays, 30)
        XCTAssertFalse(again.usesDefaultFolder)
        XCTAssertEqual(again.folder.path, chosen.path)
        again.resetFolder()
        XCTAssertTrue(again.usesDefaultFolder)
        XCTAssertEqual(Preferences(defaults: temporary.defaults).folder.lastPathComponent, "OpenNotes")
    }

    @MainActor func testEveryKeyWrittenIsFreshInstallEvidence() {
        let temporary = TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.side = .left
        preferences.display = .pointer
        preferences.hotkey = .default
        preferences.folder = FileManager.default.temporaryDirectory
        preferences.face = .mono
        preferences.color = .sky
        preferences.autoArchiveDays = 7
        let written = Set(temporary.defaults.dictionaryRepresentation().keys).intersection([
            Preferences.Key.side, Preferences.Key.display, Preferences.Key.hotkey, Preferences.Key.folder,
            Preferences.Key.face, Preferences.Key.color, Preferences.Key.autoArchiveDays,
        ])
        XCTAssertEqual(written.count, 7)
        for key in written {
            XCTAssertTrue(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(key), key)
        }
    }
}

/// The styler on a text storage: attributes only, never a character.
final class NoteStylerTests: XCTestCase {
    @MainActor func testApplyChangesAttributesOnly() {
        let text = "# Title\n- [ ] **bold** _it_ `code` https://a.b\n- [x] done"
        let storage = NSTextStorage(string: text)
        let styler = NoteStyler(face: .sans, appearance: NSAppearance(named: .aqua))
        styler.apply(to: storage)
        XCTAssertEqual(storage.string, text)
        let ns = text as NSString
        func attributes(at piece: String) -> [NSAttributedString.Key: Any] {
            storage.attributes(at: ns.range(of: piece).location, effectiveRange: nil)
        }
        let title = attributes(at: "Title")[.font] as? NSFont
        let plain = attributes(at: "done")[.font] as? NSFont
        XCTAssertGreaterThan(title?.pointSize ?? 0, plain?.pointSize ?? 0)
        XCTAssertEqual(attributes(at: "# ")[.foregroundColor] as? NSColor, styler.secondary)
        XCTAssertNotNil(attributes(at: "code")[.backgroundColor])
        XCTAssertEqual(attributes(at: "https://a.b")[.link] as? URL, URL(string: "https://a.b"))
        XCTAssertEqual(attributes(at: "done")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNotNil(attributes(at: "[x]")[.cursor])
        let boldFont = attributes(at: "bold")[.font] as? NSFont
        XCTAssertNotEqual(boldFont, plain)
        // Applied twice: idempotent.
        styler.apply(to: storage)
        XCTAssertEqual(storage.string, text)
    }

    @MainActor func testTheMonoFaceUsesTheMonoFont() {
        let storage = NSTextStorage(string: "x\ny")
        NoteStyler(face: .mono, appearance: NSAppearance(named: .darkAqua)).apply(to: storage)
        let font = storage.attributes(at: 2, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(font?.isFixedPitch ?? false)
        XCTAssertEqual(storage.attributes(at: 2, effectiveRange: nil)[.foregroundColor] as? NSColor, NSColor(hex: 0xF8F8F8))
    }

    @MainActor func testTheTextViewTogglesACheckboxThroughTheEditPath() {
        let scrollView = NoteTextView.makeScrollableTextView()
        let textView = scrollView.documentView as! NoteTextView
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        var reported: [String] = []
        textView.onTextChange = { reported.append($0) }
        textView.setText("Todo\n- [ ] milk")
        XCTAssertEqual(reported, [], "pushing text in is not an edit")
        XCTAssertEqual(textView.string, "Todo\n- [ ] milk")
        // Paste is plain text only.
        XCTAssertEqual(textView.readablePasteboardTypes, [.string])
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        // The toggle the click performs, through shouldChangeText/didChangeText.
        let toggle = MarkdownLite.toggleCheckbox(in: textView.string, at: 8)!
        XCTAssertTrue(textView.shouldChangeText(in: toggle.range, replacementString: toggle.replacement))
        textView.textStorage?.replaceCharacters(in: toggle.range, with: toggle.replacement)
        textView.didChangeText()
        XCTAssertEqual(textView.string, "Todo\n- [x] milk")
        XCTAssertEqual(reported, ["Todo\n- [x] milk"])
    }
}

/// The diagnostics line and the deck host's display choice.
final class WiringTests: XCTestCase {
    @MainActor func testDiagnosticsNameTheBuildAndTheFolder() throws {
        let temporary = TemporaryDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)
        let text = Diagnostics.text(model: model, preferences: preferences, loginItem: LoginItem(flags: temporary.defaults, service: FakeLoginItemService()), hotkeys: HotkeyCenter(), deck: nil)
        // Under xctest Bundle.main is the test host; only the shape is checked.
        XCTAssertTrue(text.hasPrefix("OpenNotes ") && text.contains(" · macOS "), text)
        XCTAssertTrue(text.contains("Licensing: off (source build"), text)
        XCTAssertTrue(text.contains("Deck: right edge · the main display · hidden"), text)
        XCTAssertTrue(text.contains("Hotkey: ⌥⌘N"), text)
        XCTAssertTrue(text.contains("watcher off"), text)
        XCTAssertTrue(text.contains("Notes: 0 active · 0 archived · 0 unsaved"), text)
    }

    @MainActor func testTheDeckHostsTheChosenDisplays() {
        let screens = NSScreen.screens
        guard let first = screens.first, let firstID = ScreenCatalog.displayID(of: first) else { return }
        XCTAssertEqual(DeckHost.hosts(for: .main, screens: screens).keys.first, firstID)
        XCTAssertEqual(DeckHost.hosts(for: .every, screens: screens).count, screens.count)
        XCTAssertEqual(DeckHost.hosts(for: .pointer, screens: screens, pointer: CGPoint(x: first.frame.midX, y: first.frame.midY)).keys.first, firstID)
        XCTAssertEqual(DeckHost.hosts(for: .pointer, screens: screens, pointer: CGPoint(x: -100_000, y: -100_000)).keys.first, firstID)
    }

    @MainActor func testTheDeckPanelConfigurationIsTheOneTheSpikeSettledOn() {
        // Over full-screen apps and Stage Manager (the implementation
        // report's spike): every Space, full-screen spaces, stationary,
        // above the status bar level.
        XCTAssertTrue(DeckPanelController.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(DeckPanelController.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(DeckPanelController.collectionBehavior.contains(.stationary))
        XCTAssertGreaterThan(DeckPanelController.level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertGreaterThan(DeckPanelController.level.rawValue, NSWindow.Level.floating.rawValue)
    }
}

private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettings() {}
}

import ServiceManagement
