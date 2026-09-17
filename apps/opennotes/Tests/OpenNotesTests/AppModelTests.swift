import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// The model over a temporary folder: the debounce, closing, archive and
/// undo, the status line. No watcher is started, no window opened.
final class AppModelTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-model-\(UUID().uuidString)", isDirectory: true)
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
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder) { [self] in clock }, watcher: FolderWatcher()) { [self] in clock }
        model.store.load(create: false)
        return model
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @MainActor func testTypingIsWrittenAfterTheDebounceAndClosingNamesTheFile() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        // New notes: a random preset (an empty deck picks by the seed alone), no font of their own.
        XCTAssertEqual(note.color, .preset(NotePaper.randomForNewNote(active: [], lastCreated: nil, seed: 0)))
        XCTAssertNil(note.typeface)
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
        // The license the model reads, moved by hand: read-only is derived
        // from it at every read, never stored.
        var allowed = false
        model.license.bind(access: { allowed }, restriction: { allowed ? nil : LicenseRestriction.trialEndedSample }, canBuy: true)
        XCTAssertTrue(model.readOnly)
        XCTAssertNil(model.createNote())
        XCTAssertTrue(model.store.readOnly)
        XCTAssertEqual(model.statusLine(for: NoteID("x")), model.readOnlyNotice)
        XCTAssertEqual(model.readOnlyNotice, LicenseRestriction.trialEndedSample.notice)
        model.setText("changed", for: NoteID("x"))
        XCTAssertEqual(model.note(NoteID("x"))?.text, "x")
        model.archive(NoteID("x"))
        XCTAssertEqual(model.archived.count, 0, "archiving is a file change: refused while read-only")
        XCTAssertEqual(try files(), ["x.md"])
        allowed = true
        XCTAssertFalse(model.readOnly)
        model.archive(NoteID("x"))
        XCTAssertEqual(model.archived.count, 1)
    }

    @MainActor func testTheConflictNoticeShowsOnceAfterAnOutsideEditDivertedOurs() throws {
        let model = makeModel()
        let url = folder.appendingPathComponent("a.md")
        try Data("A".utf8).write(to: url)
        model.store.load(create: false)
        var redirects: [(NoteID, NoteID)] = []
        model.onRedirect = { redirects.append(($0, $1)) }
        model.setText("Ours", for: NoteID("a"))
        try Data("Theirs, longer".utf8).write(to: url)
        let copy = try XCTUnwrap(model.save(NoteID("a")))
        XCTAssertNotEqual(copy, NoteID("a"))
        XCTAssertEqual(redirects.map { $0.1 }, [copy])
        XCTAssertTrue(model.statusLine(for: copy).contains("was changed outside"), model.statusLine(for: copy))
        model.clearConflictNotice()
        XCTAssertEqual(model.statusLine(for: copy), "Saved · now")
        XCTAssertEqual(try files().count, 2)
    }

    @MainActor func testArchivingWithUnsavedTextDivertedByAnOutsideEditArchivesTheConflictCopyAndUndoFollowsIt() throws {
        let model = makeModel()
        let url = folder.appendingPathComponent("a.md")
        try Data("A".utf8).write(to: url)
        model.store.load(create: false)
        model.setText("Ours", for: NoteID("a"))
        try Data("Theirs, longer".utf8).write(to: url)
        model.archive(NoteID("a"))
        let pending = try XCTUnwrap(model.pendingUndo)
        XCTAssertNotEqual(pending.ids, [NoteID("a")])
        XCTAssertEqual(pending.ids.count, 1)
        let copy = pending.ids[0]
        XCTAssertEqual(model.note(copy)?.archived, true)
        XCTAssertEqual(model.note(NoteID("a"))?.archived, false)
        model.undoArchive()
        XCTAssertEqual(model.note(copy)?.archived, false)
        XCTAssertEqual(model.note(NoteID("a"))?.archived, false)
        XCTAssertEqual(model.note(NoteID("a"))?.text, "Theirs, longer")
    }

    @MainActor func testTheSaveProblemShowsUntilTheNextSuccess() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("x", for: note.id)
        try FileManager.default.removeItem(at: folder)
        XCTAssertNil(model.save(note.id))
        XCTAssertTrue(model.statusLine(for: note.id).hasPrefix("Couldn’t save"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.store.rescan()
        XCTAssertEqual(model.save(note.id), note.id)
        XCTAssertEqual(model.statusLine(for: note.id), "Saved · now")
    }

    /// The tabs' counts come from the model's cache: a count follows the
    /// text typed here and a change found on disk, and a note without a
    /// box or with no box any more reads nil.
    @MainActor func testTheChecklistCountFollowsTypingAndOutsideEdits() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        XCTAssertNil(model.checklistProgress(for: note.id))
        model.setText("Groceries\n- [ ] milk\n- [ ] eggs", for: note.id)
        XCTAssertEqual(model.checklistProgress(for: note.id)?.label, "0/2")
        XCTAssertEqual(model.checklistProgress(for: note.id)?.label, "0/2", "the cached answer")
        model.setText("Groceries\n- [x] milk\n- [ ] eggs", for: note.id)
        XCTAssertEqual(model.checklistProgress(for: note.id)?.label, "1/2")
        model.setText("Groceries\nno boxes now", for: note.id)
        XCTAssertNil(model.checklistProgress(for: note.id))
        // Saved, then changed on disk: the rescan's `.updated` drops the cache.
        model.setText("Groceries\n- [x] milk\n- [x] eggs", for: note.id)
        let saved = try XCTUnwrap(model.save(note.id))
        XCTAssertEqual(model.checklistProgress(for: saved)?.label, "2/2")
        clock.addTimeInterval(2)
        let file = model.store.fileURL(for: saved)
        let outside = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "- [x] eggs", with: "- [ ] eggs\n- [ ] bread")
        try outside.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: file.path)
        model.store.rescan()
        XCTAssertEqual(model.checklistProgress(for: saved)?.label, "1/3")
    }
}

/// The preferences round trip, the fresh-install evidence, the folder default.
final class PreferencesTests: XCTestCase {
    @MainActor func testDefaultsAndRoundTrip() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(preferences.side, .right)
        // Every display on a fresh install (PreferencesDefaultsTests has the rest).
        XCTAssertEqual(preferences.display, .every)
        XCTAssertEqual(preferences.hotkey, .default)
        XCTAssertEqual(preferences.face, .sans)
        XCTAssertNil(preferences.font)
        XCTAssertEqual(preferences.typeface, .face(.sans))
        XCTAssertEqual(preferences.size, 14)
        XCTAssertEqual(preferences.newNoteColor, .random)
        XCTAssertEqual(preferences.autoArchiveDays, 0)
        XCTAssertTrue(preferences.usesDefaultFolder)
        // The update-test variant keeps its notes in its own folder.
        let defaultLeaf = UpdateTesting.isCompiledIn ? "Notes" : "OpenNotes"
        XCTAssertEqual(preferences.folder.lastPathComponent, defaultLeaf)
        preferences.side = .left
        preferences.display = .every
        preferences.hotkey = nil
        preferences.face = .mono
        preferences.font = "Georgia"
        preferences.size = 18
        preferences.newNoteColor = .fixed(.mint)
        preferences.autoArchiveDays = 30
        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("chosen", isDirectory: true)
        preferences.folder = chosen
        let again = Preferences(defaults: temporary.defaults)
        XCTAssertEqual(again.side, .left)
        XCTAssertEqual(again.display, .every)
        XCTAssertNil(again.hotkey)
        XCTAssertEqual(again.face, .mono)
        XCTAssertEqual(again.font, "Georgia")
        XCTAssertEqual(again.typeface, .family("Georgia"))
        XCTAssertEqual(again.size, 18)
        XCTAssertEqual(again.newNoteColor, .fixed(.mint))
        XCTAssertEqual(again.autoArchiveDays, 30)
        // A face as the default clears the family.
        again.typeface = .face(.serif)
        XCTAssertNil(Preferences(defaults: temporary.defaults).font)
        XCTAssertEqual(Preferences(defaults: temporary.defaults).typeface, .face(.serif))
        XCTAssertFalse(again.usesDefaultFolder)
        XCTAssertEqual(again.folder.path, chosen.path)
        again.resetFolder()
        XCTAssertTrue(again.usesDefaultFolder)
        XCTAssertEqual(Preferences(defaults: temporary.defaults).folder.lastPathComponent, defaultLeaf)
    }

    @MainActor func testHadEarlierPreferencesIsTrueOnlyWithStoredEvidence() throws {
        let fresh = try TemporaryDefaults()
        XCTAssertFalse(Preferences(defaults: fresh.defaults).hadEarlierPreferences)
        let seeded = try TemporaryDefaults()
        seeded.defaults.set(true, forKey: WelcomeNote.Key.decided)
        XCTAssertTrue(Preferences(defaults: seeded.defaults).hadEarlierPreferences)
        XCTAssertTrue(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(WelcomeNote.Key.decided))
    }

    @MainActor func testEveryKeyWrittenIsFreshInstallEvidence() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.side = .left
        preferences.display = .pointer
        preferences.hotkey = .default
        preferences.folder = FileManager.default.temporaryDirectory
        preferences.face = .mono
        preferences.font = "Menlo"
        preferences.size = 12
        preferences.newNoteColor = .fixed(.sky)
        preferences.autoArchiveDays = 7
        preferences.hideFromScreenSharing = true
        let written = Set(temporary.defaults.dictionaryRepresentation().keys).intersection([
            Preferences.Key.side, Preferences.Key.display, Preferences.Key.hotkey, Preferences.Key.folder,
            Preferences.Key.face, Preferences.Key.font, Preferences.Key.size, Preferences.Key.color, Preferences.Key.autoArchiveDays,
            Preferences.Key.hideFromScreenSharing, FreshInstallDefault.Key.screenSharingApplied,
        ])
        XCTAssertEqual(written.count, 11)
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

    /// ⌥⌘↑ / ⌥⌘↓ as a keyboard sends them: the arrow events carry the
    /// function and numeric-pad bits beside the modifiers, and are matched
    /// by key code (the arrows have no character). Any other modifier set
    /// on an arrow is left to the text view.
    @MainActor func testOptionCommandArrowsMoveTheNoteWhateverTheArrowBitsSay() {
        let scrollView = NoteTextView.makeScrollableTextView()
        let textView = scrollView.documentView as! NoteTextView
        var commands: [EditorCommand] = []
        textView.onCommand = { commands.append($0) }
        func arrow(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            let character = keyCode == 126 ? "\u{F700}" : "\u{F701}"
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
            )!
            return textView.performKeyEquivalent(with: event)
        }
        XCTAssertTrue(arrow(126, [.command, .option, .function, .numericPad]))
        XCTAssertTrue(arrow(125, [.command, .option, .function, .numericPad]))
        XCTAssertTrue(arrow(126, [.command, .option]))
        XCTAssertEqual(commands, [.moveUp, .moveDown, .moveUp])
        // Plain, shifted or control arrows are the text view's own.
        XCTAssertFalse(arrow(125, [.function, .numericPad]))
        XCTAssertFalse(arrow(125, [.command, .shift, .function, .numericPad]))
        XCTAssertFalse(arrow(125, [.command, .option, .control, .function, .numericPad]))
        XCTAssertEqual(commands, [.moveUp, .moveDown, .moveUp])
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

    // MARK: - Arithmetic answers, drawn and committed

    @MainActor func testApplyDimsACurrentAnswerAndStrikesAStaleOne() {
        let text = "Budget\n3 * $95 =\n2 + 2 = 4\n3 * 3 = 4"
        let storage = NSTextStorage(string: text)
        let styler = NoteStyler(face: .sans, appearance: NSAppearance(named: .aqua), locale: Locale(identifier: "en_US"))
        styler.apply(to: storage)
        XCTAssertEqual(storage.string, text)
        let ns = text as NSString
        let currentLine = ns.range(of: "2 + 2 = 4")
        let staleLine = ns.range(of: "3 * 3 = 4")
        let currentFour = ns.range(of: "4", range: currentLine)
        let staleFour = ns.range(of: "4", range: staleLine)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: currentFour.location, effectiveRange: nil) as? NSColor, styler.secondary)
        XCTAssertNil(storage.attribute(.strikethroughStyle, at: currentFour.location, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: staleFour.location, effectiveRange: nil))
    }

    @MainActor func testPreviewAttributedAppendsFreshAnswersWithoutTouchingApplysStorage() {
        let text = "Budget\n3 * $95 =\n2 + 2 = 4\n3 * 3 = 4"
        let styler = NoteStyler(face: .sans, appearance: NSAppearance(named: .aqua), locale: Locale(identifier: "en_US"))
        let preview = String(styler.previewAttributed(text).characters)
        XCTAssertTrue(preview.contains("$285"), preview)
        XCTAssertTrue(preview.contains("9"), preview)
        let storage = NSTextStorage(string: text)
        styler.apply(to: storage)
        XCTAssertEqual(storage.string, text, "the editor never writes a preview's drawn answers into the storage")
    }

    // MARK: - NoteTextView: answers, links and Tab

    /// `Budget` (the title), a fresh `=` line, a stale one, then a web
    /// link and a home-folder path.
    @MainActor private func makeAnswersAndLinksTextView() -> NoteTextView {
        let scrollView = NoteTextView.makeScrollableTextView()
        let textView = scrollView.documentView as! NoteTextView
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.styler = NoteStyler(face: .sans, appearance: NSAppearance(named: .aqua), locale: Locale(identifier: "en_US"))
        textView.setText("Budget\n3 * $95 =\n3 * 3 = 4\nSee https://a.b and ~/Notes/x.md")
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    @MainActor func testTextViewExposesTheCurrentAnswersAndLinks() {
        let textView = makeAnswersAndLinksTextView()
        XCTAssertEqual(textView.answers.count, 2)
        XCTAssertEqual(textView.links.map(\.kind), [.web, .path])
    }

    @MainActor func testInsertTabCommitsAFreshAnswerAndReportsOneChange() {
        let textView = makeAnswersAndLinksTextView()
        var reported: [String] = []
        textView.onTextChange = { reported.append($0) }
        let freshLine = (textView.string as NSString).range(of: "3 * $95 =")
        textView.setSelectedRange(NSRange(location: NSMaxRange(freshLine), length: 0))
        textView.insertTab(nil)
        XCTAssertTrue(textView.string.contains("3 * $95 = $285"), textView.string)
        XCTAssertEqual(reported.count, 1)
    }

    @MainActor func testInsertTabOnAStaleLineReplacesTheOldAnswer() {
        let textView = makeAnswersAndLinksTextView()
        let staleLine = (textView.string as NSString).range(of: "3 * 3 = 4")
        textView.setSelectedRange(NSRange(location: staleLine.location, length: 0))
        textView.insertTab(nil)
        XCTAssertTrue(textView.string.contains("3 * 3 = 9"), textView.string)
        XCTAssertFalse(textView.string.contains("3 * 3 = 4"), textView.string)
    }

    @MainActor func testInsertTabAtTheStartInsertsAnOrdinaryTab() {
        let textView = makeAnswersAndLinksTextView()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertTab(nil)
        XCTAssertTrue(textView.string.hasPrefix("\tBudget"), textView.string)
    }

    @MainActor func testInsertTabChangesNothingWhenEditingIsRefused() {
        let textView = makeAnswersAndLinksTextView()
        textView.mayEdit = { false }
        let before = textView.string
        let freshLine = (textView.string as NSString).range(of: "3 * $95 =")
        textView.setSelectedRange(NSRange(location: NSMaxRange(freshLine), length: 0))
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, before)
    }

    @MainActor func testLinkAtPointFindsTheLinkUnderItsGlyphsAndNilElsewhere() {
        let textView = makeAnswersAndLinksTextView()
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return XCTFail() }
        let webLink = try! XCTUnwrap(textView.links.first { $0.kind == .web })
        let glyphs = layoutManager.glyphRange(forCharacterRange: webLink.range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        let midpoint = NSPoint(x: rect.midX, y: rect.midY)
        XCTAssertEqual(textView.link(at: midpoint)?.text, webLink.text)
        XCTAssertNil(textView.link(at: NSPoint(x: 5, y: 5)))
    }

    // MARK: - LinkTarget

    @MainActor func testLinkTargetURLForAHomePathHasTheEscapedFileName() {
        let url = try! XCTUnwrap(LinkTarget.url(for: "~/x y.md"))
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasSuffix("/x y.md"), url.path)
    }

    @MainActor func testLinkTargetURLForAUnicodeAddress() {
        XCTAssertNotNil(LinkTarget.url(for: "https://例え.jp/道"))
    }

    @MainActor func testLinkTargetURLForMailto() {
        XCTAssertEqual(LinkTarget.url(for: "mailto:a@b.c")?.scheme, "mailto")
    }
}

/// The diagnostics line and the deck host's display choice.
final class WiringTests: XCTestCase {
    @MainActor func testDiagnosticsNameTheBuildAndTheFolder() throws {
        let temporary = try TemporaryDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)
        let text = Diagnostics.text(model: model, preferences: preferences, loginItem: LoginItem(flags: temporary.defaults, service: FakeLoginItemService()), hotkeys: HotkeyCenter(), deck: nil)
        // Under xctest Bundle.main is the test host; only the shape is checked.
        XCTAssertTrue(text.hasPrefix("OpenNotes ") && text.contains(" · macOS "), text)
        // The flavour's line: from source it says so; an official build
        // names where the license stands (here: nothing bound, so the flavour alone).
        XCTAssertTrue(text.contains(Licensing.isCompiledIn ? "Licensing: official build" : "Licensing: off (source build"), text)
        XCTAssertTrue(text.contains("Deck: right edge · every display · hidden"), text)
        XCTAssertTrue(text.contains("· Other folder · watcher off"), text)
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
