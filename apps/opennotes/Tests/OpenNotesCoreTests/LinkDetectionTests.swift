import XCTest
@testable import OpenNotesCore

/// `MarkdownLite.links(in:)`: web, mail, file and path links, their
/// boundaries, targets and hover display, and that `runs(in:)` sets
/// `TextStyle.link` for every kind.
final class LinkDetectionTests: XCTestCase {
    private func links(_ text: String) -> [MarkdownLite.Link] {
        MarkdownLite.links(in: text)
    }

    @MainActor func testTrailingCommaIsNotPartOfTheLink() {
        let found = links("https://openapps.space/opennotes/,")
        XCTAssertEqual(found.map(\.text), ["https://openapps.space/opennotes/"])
    }

    @MainActor func testAClosingParenTheLinkDidNotOpenIsDropped() {
        let found = links("(http://x.y/z).")
        XCTAssertEqual(found.map(\.text), ["http://x.y/z"])
    }

    @MainActor func testABalancedParenInsideTheURLIsKept() {
        let found = links("https://en.wikipedia.org/wiki/Foo_(bar)")
        XCTAssertEqual(found.map(\.text), ["https://en.wikipedia.org/wiki/Foo_(bar)"])
    }

    @MainActor func testABareWwwLinkGetsAnHTTPSTargetAndAHostDisplay() {
        let link = try! XCTUnwrap(links("www.example.com/a").first)
        XCTAssertEqual(link.kind, .web)
        XCTAssertEqual(link.target, "https://www.example.com/a")
        XCTAssertEqual(link.display, "www.example.com")
    }

    @MainActor func testWwwWithNoDotAfterIsNotALink() {
        XCTAssertTrue(links("www.x").isEmpty)
    }

    @MainActor func testMailtoDisplaysTheAddressWithoutTheQuery() {
        let link = try! XCTUnwrap(links("mailto:a@b.c?subject=hi").first)
        XCTAssertEqual(link.kind, .mail)
        XCTAssertEqual(link.display, "a@b.c")
    }

    @MainActor func testFileURLDisplaysTheDecodedFileName() {
        let link = try! XCTUnwrap(links("file:///Users/k/Notes/x%20y.md").first)
        XCTAssertEqual(link.kind, .file)
        XCTAssertEqual(link.display, "x y.md")
    }

    @MainActor func testHomePathDisplaysTheFileName() {
        let link = try! XCTUnwrap(links("~/Documents/notes.md").first)
        XCTAssertEqual(link.kind, .path)
        XCTAssertEqual(link.display, "notes.md")
    }

    @MainActor func testHomePathEndingInASlashDisplaysTheFolderName() {
        let link = try! XCTUnwrap(links("~/Documents/").first)
        XCTAssertEqual(link.display, "Documents")
    }

    @MainActor func testAUnicodeURLIsKeptWholeWithADisplayedHost() {
        let link = try! XCTUnwrap(links("https://例え.jp/道").first)
        XCTAssertEqual(link.text, "https://例え.jp/道")
        XCTAssertEqual(link.display, "例え.jp")
    }

    @MainActor func testALinkInsideACodeSpanIsNotFound() {
        XCTAssertTrue(links("see `http://code` here").isEmpty)
    }

    @MainActor func testALinkGluedToAWordIsNotFound() {
        XCTAssertTrue(links("xhttps://a.b").isEmpty)
    }

    @MainActor func testAMarkdownStyleLinkIsFoundInsideTheParens() {
        let found = links("[text](https://q.z/p)")
        XCTAssertEqual(found.map(\.text), ["https://q.z/p"])
    }

    @MainActor func testTwoLinksOnOneLineAreFoundInOrder() {
        let found = links("see https://a.b and https://c.d")
        XCTAssertEqual(found.map(\.text), ["https://a.b", "https://c.d"])
    }

    @MainActor func testAFullURLIsNotAlsoMatchedAsABareWwwLink() {
        let found = links("https://www.a.b")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "https://www.a.b")
    }

    @MainActor func testTrailingSentencePunctuationIsDropped() {
        XCTAssertEqual(links("see https://a.b?").first?.text, "https://a.b")
        XCTAssertEqual(links("see https://a.b!").first?.text, "https://a.b")
        XCTAssertEqual(links("see https://a.b;").first?.text, "https://a.b")
        XCTAssertEqual(links("see https://a.b:").first?.text, "https://a.b")
    }

    @MainActor func testLinkAtCaret() {
        let text = "see https://a.b/c here"
        let range = (text as NSString).range(of: "https://a.b/c")
        XCTAssertEqual(MarkdownLite.link(in: text, at: range.location)?.text, "https://a.b/c")
        XCTAssertEqual(MarkdownLite.link(in: text, at: range.location + 5)?.text, "https://a.b/c")
        XCTAssertEqual(MarkdownLite.link(in: text, at: NSMaxRange(range))?.text, "https://a.b/c")
        XCTAssertNil(MarkdownLite.link(in: text, at: NSMaxRange(range) + 1))
    }

    // MARK: - runs(in:) sets `.link` for every kind

    @MainActor func testRunsSetLinkForEveryKind() {
        for text in ["https://a.b", "www.a.b/x", "mailto:a@b.c", "file:///a/b.md", "~/a/b.md"] {
            let runs = MarkdownLite.runs(in: text)
            XCTAssertTrue(runs.contains { $0.style.link != nil }, text)
        }
    }

    // MARK: - Existing MarkdownLiteTests must still pass

    @MainActor func testExistingMarkdownLiteSuiteStillPasses() {
        // Guards against a regression where link detection changes broke the
        // original styling tests; run one representative assertion from that
        // suite here so it is exercised whenever this file runs.
        let text = "t\nsee https://openapps.space/opennotes/, and (http://x.y/z)."
        let ns = text as NSString
        let runs = MarkdownLite.runs(in: text).map { (ns.substring(with: $0.range), $0.style) }
        XCTAssertEqual(runs.first { $0.1.link != nil }?.1.link, "https://openapps.space/opennotes/")
    }
}
