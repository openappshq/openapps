import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// The font catalogue, the resolved look (font, size, the missing-family
/// fallback), the styler's fonts, and the preferences and model plumbing
/// that feed them.
final class AppearanceAppTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - FontCatalog

    @MainActor func testVisibleDropsPrivateAndBlankNamesKeepingOrder() {
        let input = [".SFNS", "Helvetica", "", "  ", ".AppleColorEmojiUI", "Menlo"]
        XCTAssertEqual(FontCatalog.visible(input), ["Helvetica", "Menlo"])
    }

    @MainActor func testMatchingIsCaseInsensitiveOverDisplayAndFamilyNameAndAnEmptyQueryReturnsEveryFamily() {
        let families = [
            FontCatalog.Family(name: "Menlo", displayName: "Menlo"),
            FontCatalog.Family(name: "Helvetica", displayName: "Helvetica"),
            FontCatalog.Family(name: "AGaramondPro", displayName: "Adobe Garamond Pro"),
        ]
        XCTAssertEqual(FontCatalog.matching("men", in: families).map(\.name), ["Menlo"])
        XCTAssertEqual(FontCatalog.matching("MEN", in: families).map(\.name), ["Menlo"])
        XCTAssertEqual(FontCatalog.matching("", in: families).count, families.count)
        XCTAssertEqual(FontCatalog.matching("  ", in: families).count, families.count)
    }

    // MARK: - NoteAppearance.resolve

    @MainActor func testResolveFallsBackToTheDefaultWhenTheNotesFamilyIsMissingAndNamesItInTheNotice() {
        let defaults = NoteAppearance.Defaults(typeface: .face(.sans), size: 14)
        let result = NoteAppearance.resolve(color: .coral, typeface: .family("Nope"), fontSize: nil, defaults: defaults, isInstalled: { _ in false })
        XCTAssertEqual(result.font, .sans)
        XCTAssertEqual(result.missingFamily, "Nope")
        XCTAssertTrue(result.missingFontNotice?.contains("Nope") ?? false, result.missingFontNotice ?? "nil")
    }

    @MainActor func testResolveKeepsTheFamilyWhenItIsInstalled() {
        let defaults = NoteAppearance.Defaults(typeface: .face(.sans), size: 14)
        let result = NoteAppearance.resolve(color: .coral, typeface: .family("Nope"), fontSize: nil, defaults: defaults, isInstalled: { _ in true })
        XCTAssertEqual(result.font, .family("Nope"))
        XCTAssertNil(result.missingFamily)
    }

    @MainActor func testResolveTakesTheDefaultWhenTheNoteNamesNoTypeface() {
        let defaults = NoteAppearance.Defaults(typeface: .family("Georgia"), size: 14)
        let result = NoteAppearance.resolve(color: .coral, typeface: nil, fontSize: nil, defaults: defaults, isInstalled: { $0 == "Georgia" })
        XCTAssertEqual(result.font, .family("Georgia"))
        XCTAssertNil(result.missingFamily)
    }

    @MainActor func testResolveFallsBackToSansWhenTheDefaultItselfIsAMissingFamilyAndTheNoteNamedNothing() {
        let defaults = NoteAppearance.Defaults(typeface: .family("Ghost"), size: 14)
        let result = NoteAppearance.resolve(color: .coral, typeface: nil, fontSize: nil, defaults: defaults, isInstalled: { _ in false })
        XCTAssertEqual(result.font, .sans)
        XCTAssertNil(result.missingFamily)
    }

    @MainActor func testResolveClampsTheNotesSizeAndFallsBackToTheDefault() {
        let defaults = NoteAppearance.Defaults(typeface: .face(.sans), size: 14)
        let tooBig = NoteAppearance.resolve(color: .coral, typeface: nil, fontSize: 30, defaults: defaults, isInstalled: { _ in true })
        XCTAssertEqual(tooBig.size, CGFloat(NoteTypeface.sizeRange.upperBound))
        let none = NoteAppearance.resolve(color: .coral, typeface: nil, fontSize: nil, defaults: defaults, isInstalled: { _ in true })
        XCTAssertEqual(none.size, CGFloat(defaults.size))
    }

    // MARK: - NoteStyler fonts

    @MainActor func testTheStylerSetsTheNotesOwnFamilyOnTheTextAndTheCheckbox() {
        let styler = NoteStyler(look: NoteAppearance(font: .family("Menlo")), appearance: NSAppearance(named: .aqua))
        let text = "x\n- [ ] y"
        let storage = NSTextStorage(string: text)
        styler.apply(to: storage)
        let ns = text as NSString
        let textFont = storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(textFont?.isFixedPitch ?? false)
        let checkboxFont = storage.attributes(at: ns.range(of: "[ ]").location, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(checkboxFont?.isFixedPitch ?? false)
    }

    @MainActor func testAFamilyWithItsOwnItalicMemberIsUsedDirectlyNoObliqueness() {
        let styler = NoteStyler(look: NoteAppearance(font: .family("Georgia")), appearance: NSAppearance(named: .aqua))
        let text = "x _it_ y"
        let storage = NSTextStorage(string: text)
        styler.apply(to: storage)
        let ns = text as NSString
        let attributes = storage.attributes(at: ns.range(of: "it").location, effectiveRange: nil)
        let font = attributes[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertNil(attributes[.obliqueness])
    }

    @MainActor func testAFaceWithNoItalicMemberIsSlantedWithObliquenessInstead() {
        AppResources.registerFonts()
        let styler = NoteStyler(look: NoteAppearance(font: .sans), appearance: NSAppearance(named: .aqua))
        let text = "x _it_ y"
        let storage = NSTextStorage(string: text)
        styler.apply(to: storage)
        let ns = text as NSString
        let attributes = storage.attributes(at: ns.range(of: "it").location, effectiveRange: nil)
        let font = attributes[.font] as? NSFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? true)
        XCTAssertEqual(attributes[.obliqueness] as? CGFloat, 0.18)
    }

    // MARK: - Preferences

    @MainActor func testNewNoteColorRoundTripsRandomAndAHex() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.newNoteColor = .random
        XCTAssertEqual(Preferences(defaults: temporary.defaults).newNoteColor, .random)
        preferences.newNoteColor = .fixed(.custom(0x7BAF9E))
        XCTAssertEqual(Preferences(defaults: temporary.defaults).newNoteColor, .fixed(.custom(0x7BAF9E)))
    }

    @MainActor func testA010StoredColourNameReadsAsThatFixedPreset() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set("mint", forKey: Preferences.Key.color)
        XCTAssertEqual(Preferences(defaults: temporary.defaults).newNoteColor, .fixed(.mint))
    }

    @MainActor func testAnUnknownStoredColourReadsAsRandom() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set("bogus", forKey: Preferences.Key.color)
        XCTAssertEqual(Preferences(defaults: temporary.defaults).newNoteColor, .random)
    }

    @MainActor func testColorForNewNoteHonoursAFixedCustomColourOrPicksAPresetWhenRandom() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.newNoteColor = .fixed(.custom(0x123456))
        XCTAssertEqual(preferences.colorForNewNote(active: [], lastCreated: nil, seed: 0), .custom(0x123456))
        preferences.newNoteColor = .random
        XCTAssertNotNil(preferences.colorForNewNote(active: [], lastCreated: nil, seed: 0).preset)
    }

    // MARK: - AppModel

    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-appearance-app-\(UUID().uuidString)", isDirectory: true)
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

    private func fileContents(_ id: NoteID) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(id.fileName), encoding: .utf8)
    }

    @MainActor func testTwoNewNotesInARowTakeDifferentColours() throws {
        let model = makeModel()
        let first = try XCTUnwrap(model.createNote())
        let second = try XCTUnwrap(model.createNote())
        XCTAssertNotEqual(first.color, second.color)
    }

    @MainActor func testAFixedNewNoteColourIsUsedForEveryNewNote() throws {
        let model = makeModel()
        model.preferences.newNoteColor = .fixed(.slate)
        let note = try XCTUnwrap(model.createNote())
        XCTAssertEqual(note.color, .slate)
    }

    @MainActor func testSettingAFamilyIsReportedByAppearanceAndWrittenToTheFile() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Groceries", for: note.id)
        model.setTypeface(.family("Menlo"), for: note.id)
        model.save(note.id)
        let current = try XCTUnwrap(model.note(note.id))
        XCTAssertEqual(model.appearance(of: current).font, .family("Menlo"))
        XCTAssertTrue(try fileContents(note.id).contains("font: \"Menlo\""))
    }

    @MainActor func testSettingTheFontSizeIsWrittenToTheFile() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Groceries", for: note.id)
        model.setFontSize(18, for: note.id)
        model.save(note.id)
        XCTAssertTrue(try fileContents(note.id).contains("size: 18"))
    }

    @MainActor func testClearingTheTypefaceLeavesNoFaceOrFontLine() throws {
        let model = makeModel()
        let note = try XCTUnwrap(model.createNote())
        model.setText("Groceries", for: note.id)
        model.setTypeface(.family("Menlo"), for: note.id)
        model.save(note.id)
        model.setTypeface(nil, for: note.id)
        model.save(note.id)
        let contents = try fileContents(note.id)
        XCTAssertFalse(contents.contains("face:"), contents)
        XCTAssertFalse(contents.contains("font:"), contents)
    }
}
