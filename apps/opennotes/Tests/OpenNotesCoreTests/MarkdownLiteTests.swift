import XCTest
@testable import OpenNotesCore

/// The styler: what each marker does, and that runs always tile the text.
final class MarkdownLiteTests: XCTestCase {
    private func styles(_ text: String) -> [(String, MarkdownLite.TextStyle)] {
        let ns = text as NSString
        return MarkdownLite.runs(in: text).map { (ns.substring(with: $0.range), $0.style) }
    }

    private func assertTiles(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let runs = MarkdownLite.runs(in: text)
        var expected = 0
        for run in runs {
            XCTAssertEqual(run.range.location, expected, "runs must be contiguous", file: file, line: line)
            XCTAssertGreaterThan(run.range.length, 0, file: file, line: line)
            expected = NSMaxRange(run.range)
        }
        XCTAssertEqual(expected, (text as NSString).length, "runs must cover the text", file: file, line: line)
    }

    @MainActor func testEmptyTextHasNoRuns() {
        XCTAssertEqual(MarkdownLite.runs(in: ""), [])
    }

    @MainActor func testTheFirstNonEmptyLineIsTheTitle() {
        let runs = styles("\n\nGroceries\nmilk")
        XCTAssertEqual(runs.map(\.0), ["\n\n", "Groceries", "\nmilk"])
        XCTAssertFalse(runs[0].1.isTitle)
        XCTAssertTrue(runs[1].1.isTitle)
        XCTAssertFalse(runs[2].1.isTitle)
        assertTiles("\n\nGroceries\nmilk")
    }

    @MainActor func testHeadingsKeepTheirMarkerDimmed() {
        let runs = styles("# Title\n## Two\n#### not a heading\n#nospace")
        XCTAssertEqual(runs[0].0, "# ")
        XCTAssertTrue(runs[0].1.isMarker)
        XCTAssertEqual(runs[0].1.heading, 1)
        XCTAssertTrue(runs[0].1.isTitle)
        XCTAssertEqual(runs[1].0, "Title")
        XCTAssertEqual(runs[1].1.heading, 1)
        XCTAssertFalse(runs[1].1.isMarker)
        let two = runs.first { $0.0 == "Two" }
        XCTAssertEqual(two?.1.heading, 2)
        XCTAssertFalse(two?.1.isTitle ?? true)
        XCTAssertNil(runs.first { $0.0.contains("not a heading") }?.1.heading)
        XCTAssertNil(runs.first { $0.0 == "#nospace" }?.1.heading)
        assertTiles("# Title\n## Two\n#### not a heading\n#nospace")
    }

    @MainActor func testBoldItalicAndCode() {
        let text = "t\nsome **bold** and _it_ and *it2* and `co de` here"
        let runs = styles(text)
        func style(of piece: String) -> MarkdownLite.TextStyle? { runs.first { $0.0 == piece }?.1 }
        XCTAssertEqual(style(of: "bold")?.isBold, true)
        XCTAssertEqual(style(of: "**")?.isMarker, true)
        XCTAssertEqual(style(of: "it")?.isItalic, true)
        XCTAssertEqual(style(of: "it2")?.isItalic, true)
        XCTAssertEqual(style(of: "co de")?.isCode, true)
        XCTAssertEqual(style(of: "`")?.isMarker, true)
        XCTAssertEqual(style(of: " and ")?.isBold, false)
        assertTiles(text)
    }

    @MainActor func testNothingInsideCodeIsInterpreted() {
        let runs = styles("t\n`**not bold** _x_`")
        XCTAssertEqual(runs.map(\.0), ["t", "\n", "`", "**not bold** _x_", "`"])
        XCTAssertFalse(runs[3].1.isBold)
        XCTAssertTrue(runs[3].1.isCode)
    }

    @MainActor func testUnderscoresInsideWordsAreNotItalic() {
        let runs = styles("t\nsnake_case_name and 2*3*4")
        XCTAssertTrue(runs.allSatisfy { !$0.1.isItalic })
    }

    @MainActor func testUnclosedMarkersStayPlain() {
        let runs = styles("t\n**open and *lonely and `tick")
        XCTAssertTrue(runs.allSatisfy { !$0.1.isBold && !$0.1.isItalic && !$0.1.isCode && !$0.1.isMarker })
    }

    @MainActor func testListsAndChecklists() {
        let text = "Todo\n- milk\n* eggs\n1. first\n- [ ] open\n- [x] done\n-nolist\n  - nested"
        let runs = styles(text)
        func run(_ piece: String) -> MarkdownLite.TextStyle? { runs.first { $0.0 == piece }?.1 }
        XCTAssertEqual(run("- ")?.isMarker, true)
        XCTAssertEqual(run("- ")?.isListItem, true)
        XCTAssertEqual(run("milk")?.isListItem, true)
        XCTAssertEqual(run("* ")?.isMarker, true)
        XCTAssertEqual(run("1. ")?.isMarker, true)
        XCTAssertEqual(run("[ ]")?.checkbox, false)
        XCTAssertEqual(run("[ ]")?.isMarker, true)
        XCTAssertEqual(run("[x]")?.checkbox, true)
        XCTAssertEqual(run(" done")?.isChecked, true)
        XCTAssertEqual(run(" open")?.isChecked, false)
        // "-nolist" is plain, so it merges with the newlines around it; the
        // nested bullet's indentation is plain too.
        XCTAssertEqual(run("\n-nolist\n  ")?.isListItem, false)
        XCTAssertEqual(run("- ")?.isMarker, true)
        XCTAssertEqual(runs.last?.0, "nested")
        XCTAssertEqual(runs.last?.1.isListItem, true)
        assertTiles(text)
    }

    @MainActor func testCheckboxesAreFoundAndToggledInPlace() {
        let text = "Todo\n- [ ] milk\n- [x] eggs\nplain\n- [ ]"
        let boxes = MarkdownLite.checkboxes(in: text)
        XCTAssertEqual(boxes.map(\.checked), [false, true, false])
        XCTAssertEqual((text as NSString).substring(with: boxes[0].range), "[ ]")
        // A click anywhere on the line toggles its box; the replacement is three characters for three.
        let onMilk = MarkdownLite.toggleCheckbox(in: text, at: 12)
        XCTAssertEqual(onMilk?.range, boxes[0].range)
        XCTAssertEqual(onMilk?.replacement, "[x]")
        let onEggs = MarkdownLite.toggleCheckbox(in: text, at: NSMaxRange(boxes[1].lineRange) - 1)
        XCTAssertEqual(onEggs?.replacement, "[ ]")
        XCTAssertNil(MarkdownLite.toggleCheckbox(in: text, at: 2))
        XCTAssertNil(MarkdownLite.toggleCheckbox(in: text, at: (text as NSString).range(of: "plain").location))
        // The end of an unterminated last line still belongs to it.
        XCTAssertEqual(MarkdownLite.toggleCheckbox(in: text, at: (text as NSString).length)?.replacement, "[x]")
        // The start of the next line is not the previous line.
        XCTAssertEqual(MarkdownLite.toggleCheckbox(in: text, at: boxes[1].lineRange.location)?.range, boxes[1].range)
    }

    @MainActor func testURLsAreLinksWithoutTrailingPunctuation() {
        let text = "t\nsee https://openapps.space/opennotes/, and (http://x.y/z)."
        let runs = styles(text)
        XCTAssertEqual(runs.first { $0.1.link != nil }?.1.link, "https://openapps.space/opennotes/")
        XCTAssertEqual(runs.filter { $0.1.link != nil }.map(\.0), ["https://openapps.space/opennotes/", "http://x.y/z"])
        assertTiles(text)
    }

    @MainActor func testPlainTextStripsEmphasisAndHeadingsButKeepsLists() {
        let text = "# Title\n- [ ] **bold** task\n1. _it_ and `code`\nhttps://a.b"
        XCTAssertEqual(MarkdownLite.plainText(text), "Title\n- [ ] bold task\n1. it and code\nhttps://a.b")
    }

    @MainActor func testStylingNeverChangesTheCharacterCount() {
        for text in ["", "a", "**", "- [ ] x\n", "# \n\n\n", "emoji 🙂 **bold 🙂** `x`", String(repeating: "- [ ] item\n", count: 50)] {
            assertTiles(text)
        }
    }
}
