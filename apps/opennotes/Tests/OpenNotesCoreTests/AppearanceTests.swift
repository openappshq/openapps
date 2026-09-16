import XCTest
@testable import OpenNotesCore

/// The colours a note can take: every preset's contrast, the custom hex
/// format, the dark-mode derivation, and the front matter that stores them
/// alongside a note's own font.
final class AppearanceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - Preset contrast

    @MainActor func testEveryPresetReadsAtOrAboveMinimumContrastInBothAppearances() {
        for paper in NotePaper.allCases {
            let color = NoteColor.preset(paper)
            for dark in [false, true] {
                let face = color.face(dark: dark)
                let ink = color.ink(dark: dark)
                let secondary = color.inkSecondary(dark: dark)
                XCTAssertGreaterThanOrEqual(NotePaper.contrast(ink, face), NotePaper.minimumContrast, "\(paper) dark=\(dark) ink")
                XCTAssertGreaterThanOrEqual(NotePaper.contrast(secondary, face), NotePaper.minimumContrast, "\(paper) dark=\(dark) inkSecondary")
            }
        }
    }

    @MainActor func testGraphiteTakesTheDarkInkInBothAppearancesEveryOtherPresetTakesTheLightInkInLightMode() {
        for paper in NotePaper.allCases {
            let color = NoteColor.preset(paper)
            if paper == .graphite {
                XCTAssertEqual(color.ink(dark: false), NotePaper.darkInk, "\(paper)")
                XCTAssertEqual(color.ink(dark: true), NotePaper.darkInk, "\(paper)")
            } else {
                XCTAssertEqual(color.ink(dark: false), NotePaper.lightInk, "\(paper)")
            }
        }
    }

    // MARK: - The 0.1.0 names

    /// Every name OpenNotes 0.1.0 shipped still parses, so an old file's
    /// `color:` line reads the same preset it always did (the presets added
    /// since sit among them in the menu's order, not after them).
    @MainActor func test010NamesStillParseToTheirPresets() {
        let names: [(String, NotePaper)] = [("coral", .coral), ("yellow", .yellow), ("mint", .mint), ("sky", .sky), ("lilac", .lilac), ("paper", .paper)]
        for (name, paper) in names {
            XCTAssertEqual(NoteColor(rawValue: name), .preset(paper), name)
        }
    }

    // MARK: - Hex round trip

    @MainActor func testHexRoundTrip() {
        XCTAssertEqual(NoteColor(rawValue: "#7baf9e"), .custom(0x7BAF9E))
        XCTAssertEqual(NoteColor.custom(0x7BAF9E).rawValue, "#7BAF9E")
    }

    @MainActor func testShortHexExpandsEachDigit() {
        XCTAssertEqual(NoteColor(rawValue: "#abc"), .custom(0xAABBCC))
    }

    @MainActor func testInvalidColoursDoNotParse() {
        XCTAssertNil(NoteColor(rawValue: "#12345"))
        XCTAssertNil(NoteColor(rawValue: "#GGGGGG"))
        XCTAssertNil(NoteColor(rawValue: "tomato"))
    }

    // MARK: - Dark-mode derivation

    @MainActor func testDerivedDarkIsDeterministic() {
        XCTAssertEqual(NotePaper.derivedDark(from: 0x7BAF9E), NotePaper.derivedDark(from: 0x7BAF9E))
    }

    @MainActor func testDerivedDarkKeepsTheInkContrastAcrossASweepOfColours() {
        var sweep: [UInt32] = [0x000000, 0xFFFFFF]
        let steps: [UInt32] = [0x00, 0x33, 0x66, 0x99, 0xCC, 0xFF]
        for r in steps {
            for g in steps {
                for b in steps {
                    sweep.append((r << 16) | (g << 8) | b)
                }
            }
        }
        for rgb in sweep {
            let dark = NotePaper.derivedDark(from: rgb)
            XCTAssertGreaterThanOrEqual(NotePaper.contrast(NotePaper.darkInk, dark), NotePaper.minimumContrast, String(format: "#%06X", rgb))
        }
    }

    @MainActor func testDerivedDarkKeepsAGreyGrey() {
        for value: UInt32 in [0x00, 0x20, 0x55, 0x80, 0xAA, 0xD0, 0xFF] {
            let grey = (value << 16) | (value << 8) | value
            let dark = NotePaper.derivedDark(from: grey)
            let r = (dark >> 16) & 0xFF, g = (dark >> 8) & 0xFF, b = dark & 0xFF
            XCTAssertEqual(r, g, String(format: "#%06X", grey))
            XCTAssertEqual(g, b, String(format: "#%06X", grey))
        }
    }

    @MainActor func testABrightColoursDarkPaperIsDarkerThanItsLightFace() {
        let light: UInt32 = 0xFFC0AB
        let dark = NotePaper.derivedDark(from: light)
        XCTAssertGreaterThan(NotePaper.contrast(dark, 0xFFFFFF), NotePaper.contrast(light, 0xFFFFFF))
    }

    // MARK: - Ink flip

    @MainActor func testInkFlipsToWhicheverReadsOnTheFace() {
        XCTAssertEqual(NoteColor.custom(0x202020).ink(dark: false), NotePaper.darkInk)
        XCTAssertEqual(NoteColor.custom(0xFFF3B0).ink(dark: false), NotePaper.lightInk)
    }

    // MARK: - Front matter

    @MainActor func testSerializingAFamilyAndSizeAndCustomColourRoundTrips() {
        let note = Note(id: NoteID("g"), text: "Body", color: .custom(0x7BAF9E), typeface: .family("Source Serif 4"), fontSize: 16, created: date)
        let contents = FrontMatter.serialize(note)
        XCTAssertTrue(contents.contains("color: \"#7BAF9E\""), contents)
        XCTAssertTrue(contents.contains("font: \"Source Serif 4\""), contents)
        XCTAssertTrue(contents.contains("size: 16"), contents)
        XCTAssertFalse(contents.contains("face:"), contents)
        let back = NoteStore.parse(id: note.id, contents: contents, fileDate: date, fallbackCreated: .distantPast)
        XCTAssertEqual(back.typeface, .family("Source Serif 4"))
        XCTAssertEqual(back.fontSize, 16)
        XCTAssertEqual(back.color, .custom(0x7BAF9E))
    }

    @MainActor func testANoteWithNoTypefaceOfItsOwnWritesNoFaceFontOrSizeLine() {
        let note = Note(id: NoteID("g"), text: "Body", typeface: nil, fontSize: nil, created: date)
        let contents = FrontMatter.serialize(note)
        XCTAssertFalse(contents.contains("face:"), contents)
        XCTAssertFalse(contents.contains("font:"), contents)
        XCTAssertFalse(contents.contains("size:"), contents)
    }

    @MainActor func testANoteWithAFaceWritesFaceLine() {
        let note = Note(id: NoteID("g"), text: "Body", typeface: .face(.serif), created: date)
        XCTAssertTrue(FrontMatter.serialize(note).contains("face: serif"))
    }

    @MainActor func testA010FileWithOnlyFaceParsesAsThatFace() {
        let contents = "---\nface: mono\n---\n\nBody"
        let parsed = FrontMatter.parse(contents)
        XCTAssertTrue(parsed.hadFrontMatter)
        XCTAssertEqual(parsed.typeface, .face(.mono))
    }

    @MainActor func testAFileWithBothFaceAndFontKeepsTheFamily() {
        let contents = "---\nface: sans\nfont: \"Menlo\"\n---\n\nBody"
        let parsed = FrontMatter.parse(contents)
        XCTAssertEqual(parsed.typeface, .family("Menlo"))
    }

    @MainActor func testFrontMatterKeysListsFontAndSize() {
        XCTAssertTrue(FrontMatter.keys.contains("font"))
        XCTAssertTrue(FrontMatter.keys.contains("size"))
    }

    @MainActor func testAnUnknownColourAmongKnownKeysIsConsumedWithNoColour() {
        let contents = "---\ncolor: tomato\norder: 1\n---\n\nBody"
        let parsed = FrontMatter.parse(contents)
        XCTAssertTrue(parsed.hadFrontMatter)
        XCTAssertNil(parsed.color)
        XCTAssertEqual(parsed.order, 1)
    }

    @MainActor func testAnUnknownColourAloneIsNotOurs() {
        // Mirrors testForeignFrontMatterIsLeftAsText in NoteTests: no key
        // OpenNotes recognises was actually read, so the block is left as text.
        let contents = "---\ncolor: tomato\n---\n\nBody"
        let parsed = FrontMatter.parse(contents)
        XCTAssertFalse(parsed.hadFrontMatter)
        XCTAssertEqual(parsed.text, contents)
    }

    // MARK: - Store round trip

    @MainActor func testStoreClampsAnOutOfRangeSizeOnParse() {
        let tooBig = "---\ncolor: coral\nsize: 99\n---\n\nBody"
        let tooSmall = "---\ncolor: coral\nsize: 2\n---\n\nBody"
        XCTAssertEqual(NoteStore.parse(id: NoteID("a"), contents: tooBig, fileDate: date, fallbackCreated: date).fontSize, 24)
        XCTAssertEqual(NoteStore.parse(id: NoteID("b"), contents: tooSmall, fileDate: date, fallbackCreated: date).fontSize, 10)
    }

    @MainActor func testStoreRoundTripsTypefaceFontSizeAndColourThroughAFreshLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-appearance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = date
        let store = NoteStore(folder: folder) { clock }
        store.load(create: true)
        let note = try store.create(color: .sand, typeface: .family("Menlo"))
        try store.setText("Hello", for: note.id)
        XCTAssertEqual(try store.save(note.id), .saved)
        try store.setFontSize(20, for: note.id)

        let reloaded = NoteStore(folder: folder) { clock }
        reloaded.load(create: false)
        let again = try XCTUnwrap(reloaded.note(note.id))
        XCTAssertEqual(again.typeface, .family("Menlo"))
        XCTAssertEqual(again.fontSize, 20)
        XCTAssertEqual(again.color, .sand)

        try store.setTypeface(nil, for: note.id)
        let contents = try String(contentsOf: folder.appendingPathComponent(note.id.fileName), encoding: .utf8)
        XCTAssertFalse(contents.contains("face:"), contents)
        XCTAssertFalse(contents.contains("font:"), contents)
    }

    // MARK: - Toggling

    @MainActor func testFaceTogglesSansSerifMonoSans() {
        XCTAssertEqual(NoteFace.sans.toggled, .serif)
        XCTAssertEqual(NoteFace.serif.toggled, .mono)
        XCTAssertEqual(NoteFace.mono.toggled, .sans)
    }

    @MainActor func testATypefaceInAFamilyTogglesToTheFirstFace() {
        XCTAssertEqual(NoteTypeface.family("Menlo").toggled, .face(.sans))
    }

    // MARK: - Random pick for a new note

    @MainActor func testRandomForNewNoteIsDeterministicForTheSameInputs() {
        let pinned = Note(id: NoteID("p"), color: .coral, pinned: true, order: 0, created: date)
        let yellow = Note(id: NoteID("y"), color: .yellow, order: 1, created: date)
        let mint = Note(id: NoteID("m"), color: .mint, order: 2, created: date)
        let active = [pinned, yellow, mint]
        let lastCreated = Note(id: NoteID("s"), color: .sky, created: date)
        let a = NotePaper.randomForNewNote(active: active, lastCreated: lastCreated, seed: 7)
        let b = NotePaper.randomForNewNote(active: active, lastCreated: lastCreated, seed: 7)
        XCTAssertEqual(a, b)
    }

    @MainActor func testRandomForNewNoteAvoidsTheLastCreatedAndBothLandingNeighbours() {
        let pinned = Note(id: NoteID("p"), color: .coral, pinned: true, order: 0, created: date)
        let yellow = Note(id: NoteID("y"), color: .yellow, order: 1, created: date)
        let mint = Note(id: NoteID("m"), color: .mint, order: 2, created: date)
        let active = [pinned, yellow, mint]
        let lastCreated = Note(id: NoteID("s"), color: .sky, created: date)
        for seed in 0..<50 {
            let result = NotePaper.randomForNewNote(active: active, lastCreated: lastCreated, seed: seed)
            XCTAssertNotEqual(result, .coral, "seed \(seed)")
            XCTAssertNotEqual(result, .yellow, "seed \(seed)")
            XCTAssertNotEqual(result, .sky, "seed \(seed)")
        }
    }

    @MainActor func testRandomForNewNoteStillReturnsAPresetWhenEveryOneIsExcluded() {
        let everything = NotePaper.allCases.map(NoteColor.preset)
        let result = NotePaper.pick(avoiding: everything, seed: 3)
        XCTAssertTrue(NotePaper.allCases.contains(result))
    }

    @MainActor func testRandomForNewNoteSpreadsOverMoreThanOnePresetAcrossSeeds() {
        let results = Set((0..<50).map { NotePaper.pick(avoiding: [], seed: $0) })
        XCTAssertGreaterThan(results.count, 1)
    }

    // MARK: - Contrast for every text role (ink, secondary, link)

    /// The grey ramp, plus the review's specific greys and a few saturated
    /// midtones: every role still reads at its floor in both appearances.
    @MainActor func testEveryTextRoleReadsAtItsFloorAcrossAGreyRampAndSomeMidtones() {
        var customs = stride(from: UInt32(0), through: 255, by: 17).map { $0 << 16 | $0 << 8 | $0 }
        customs += [0x777777, 0x7BAF9E, 0xE06030, 0x3080D0, 0x40A040]
        let validInks: Set<UInt32> = [NotePaper.lightInk, NotePaper.darkInk, 0x000000, 0xFFFFFF]
        for rgb in customs {
            let color = NoteColor.custom(rgb)
            for dark in [false, true] {
                let label = String(format: "#%06X dark=\(dark)", rgb)
                let face = color.face(dark: dark)
                let ink = color.ink(dark: dark)
                XCTAssertGreaterThanOrEqual(NotePaper.contrast(ink, face), NotePaper.minimumContrast, label)
                XCTAssertTrue(validInks.contains(ink), label + " ink=" + String(format: "#%06X", ink))
                XCTAssertGreaterThanOrEqual(NotePaper.contrast(color.inkSecondary(dark: dark), face), NotePaper.minimumSecondaryContrast, label)
                XCTAssertGreaterThanOrEqual(NotePaper.contrast(color.link(dark: dark), face), NotePaper.minimumSecondaryContrast, label)
            }
        }
    }

    /// A genuine midtone: neither brand ink reaches 4.5:1, so light mode
    /// falls all the way to pure black (the higher of the two contrasts).
    @MainActor func testAMidtoneNoBrandInkReachesFallsToPureBlackOrWhite() {
        let color = NoteColor.custom(0x777777)
        let face = color.face(dark: false)
        XCTAssertLessThan(NotePaper.contrast(NotePaper.lightInk, face), NotePaper.minimumContrast)
        XCTAssertLessThan(NotePaper.contrast(NotePaper.darkInk, face), NotePaper.minimumContrast)
        XCTAssertEqual(color.ink(dark: false), 0x000000)
    }

    @MainActor func testEveryPresetsLinkReadsAtTheSecondaryFloorInBothAppearances() {
        for paper in NotePaper.allCases {
            let color = NoteColor.preset(paper)
            for dark in [false, true] {
                XCTAssertGreaterThanOrEqual(NotePaper.contrast(color.link(dark: dark), color.face(dark: dark)), NotePaper.minimumSecondaryContrast, "\(paper) dark=\(dark)")
            }
        }
    }

    @MainActor func testPresetsTakeTheBrandSecondaryOfTheBodysPolarity() {
        for paper in NotePaper.allCases {
            let color = NoteColor.preset(paper)
            XCTAssertEqual(color.inkSecondary(dark: true), NotePaper.darkInkSecondary, "\(paper) dark")
            if paper == .graphite {
                XCTAssertEqual(color.inkSecondary(dark: false), NotePaper.darkInkSecondary, "\(paper) light")
            } else {
                XCTAssertEqual(color.inkSecondary(dark: false), NotePaper.lightInkSecondary, "\(paper) light")
            }
        }
    }

    @MainActor func testSecondaryAndLinkInkAreDeterministicForACustomColour() {
        let color = NoteColor.custom(0x7BAF9E)
        XCTAssertEqual(color.inkSecondary(dark: false), color.inkSecondary(dark: false))
        XCTAssertEqual(color.link(dark: false), color.link(dark: false))
    }

    @MainActor func testLinkOnASoftCustomColourIsNotTheBaseAccentButAShadeThatReachesTheFloor() {
        let color = NoteColor.custom(0x7BAF9E)
        let face = color.face(dark: false)
        XCTAssertLessThan(NotePaper.contrast(0xA53A20, face), NotePaper.minimumSecondaryContrast)
        let link = color.link(dark: false)
        XCTAssertNotEqual(link, 0xA53A20)
        XCTAssertGreaterThanOrEqual(NotePaper.contrast(link, face), NotePaper.minimumSecondaryContrast)
    }
}
