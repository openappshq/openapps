import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// "Keep notes out of screen sharing" (design/products/opennotes.md,
/// "The deck"): only the surfaces that show a note's text take
/// `sharingType = .none`; Settings and the setup guide are always shared.
/// These prove the property the app sets and how the setter behaves on
/// this OS (a one-way ratchet) — never that any capture tool honours it,
/// which is a request macOS may ignore and nothing here can check.
final class ScreenSharingSharingTypeTests: XCTestCase {
    @MainActor func testOnlyDeckAndAllNotesAskForNoneWhenTheSettingIsOn() {
        for surface in ScreenSharing.Surface.allCases {
            let type = ScreenSharing.sharingType(for: surface, hidden: true)
            switch surface {
            case .deck, .allNotes:
                XCTAssertEqual(type, .none, "\(surface)")
            case .settings, .onboarding:
                XCTAssertEqual(type, .readOnly, "\(surface)")
            }
        }
    }

    @MainActor func testEverySurfaceIsReadOnlyWhenTheSettingIsOff() {
        for surface in ScreenSharing.Surface.allCases {
            XCTAssertEqual(ScreenSharing.sharingType(for: surface, hidden: false), .readOnly, "\(surface)")
        }
    }

    @MainActor func testTheSetterNeverRaisesSharingTypeFromNoneAndApplySaysSo() {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertTrue(ScreenSharing.apply(to: window, surface: .deck, hidden: true))
        XCTAssertEqual(window.sharingType, .none)
        // Once hidden, macOS never raises it again: the caller is told to
        // recreate the window instead of trusting this one to show again.
        XCTAssertFalse(ScreenSharing.apply(to: window, surface: .deck, hidden: false))
        XCTAssertEqual(window.sharingType, .none)
    }

    @MainActor func testAFreshWindowTakesReadOnly() {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertTrue(ScreenSharing.apply(to: window, surface: .deck, hidden: false))
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    @MainActor func testASurfaceThatNeverAsksForNoneAlwaysSucceeds() {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertTrue(ScreenSharing.apply(to: window, surface: .settings, hidden: true))
        XCTAssertEqual(window.sharingType, .readOnly)
    }

}

/// The pasteboard side of "drop to create" (design/products/opennotes.md,
/// "Drop to create"): what each pasteboard item becomes, and the cursor
/// badge for what a drop would make.
final class DeckDropPasteboardTests: XCTestCase {
    private func pasteboardItem(_ pairs: [(NSPasteboard.PasteboardType, String)]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, value) in pairs { item.setString(value, forType: type) }
        return item
    }

    private func filePath(_ item: DropPayload.Item?) -> String? {
        if case .file(let url) = item { return url.path }
        return nil
    }

    private func urlValue(_ item: DropPayload.Item?) -> URL? {
        if case .url(let url) = item { return url }
        return nil
    }

    @MainActor func testAFileURLItemIsAFile() {
        let item = pasteboardItem([(.fileURL, "file:///Users/x/notes.md")])
        XCTAssertEqual(filePath(DeckDrop.item(from: item)), "/Users/x/notes.md")
    }

    @MainActor func testAURLItemWithHTTPSIsAURL() {
        let item = pasteboardItem([(.URL, "https://openapps.space")])
        XCTAssertEqual(urlValue(DeckDrop.item(from: item)), URL(string: "https://openapps.space"))
    }

    @MainActor func testAURLItemCarryingAFileURLIsAFile() {
        let item = pasteboardItem([(.URL, "file:///Users/x/notes.md")])
        XCTAssertEqual(filePath(DeckDrop.item(from: item)), "/Users/x/notes.md")
    }

    @MainActor func testAStringItemIsText() {
        let item = pasteboardItem([(.string, "hello")])
        XCTAssertEqual(DeckDrop.item(from: item), .text("hello"))
    }

    @MainActor func testAURLTypeWinsOverAStringTypeOnTheSameItem() {
        let item = pasteboardItem([(.URL, "https://openapps.space"), (.string, "https://openapps.space")])
        XCTAssertEqual(urlValue(DeckDrop.item(from: item)), URL(string: "https://openapps.space"))
    }

    @MainActor func testAnItemWithNoneOfTheThreeTypesIsSkipped() {
        let item = NSPasteboardItem()
        item.setString("x", forType: .tabularText)
        XCTAssertNil(DeckDrop.item(from: item))
    }

    @MainActor func testOperationIsLinkOnlyWhenEveryItemIsAFile() {
        let file = DropPayload.Item.file(URL(fileURLWithPath: "/tmp/a.md"))
        let file2 = DropPayload.Item.file(URL(fileURLWithPath: "/tmp/b.md"))
        let text = DropPayload.Item.text("hi")
        let url = DropPayload.Item.url(URL(string: "https://a.b")!)
        XCTAssertEqual(DeckDrop.operation(for: [file, file2]), .link)
        XCTAssertEqual(DeckDrop.operation(for: [file, text]), .copy)
        XCTAssertEqual(DeckDrop.operation(for: [text, url]), .copy)
    }

    @MainActor func testOperationIsEmptyWhenNothingMakesANote() {
        XCTAssertEqual(DeckDrop.operation(for: []), [])
        XCTAssertEqual(DeckDrop.operation(for: [.text("   ")]), [])
    }
}
