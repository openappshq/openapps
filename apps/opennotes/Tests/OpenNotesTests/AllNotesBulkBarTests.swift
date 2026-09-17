import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// The selection bar docked at the foot of the list: which chips
/// `AllNotesBulkAction.bar` offers for a scope, the checkbox glyph the
/// row and header draw (`RoundCheckboxGlyph`), and when the bar itself
/// is up. No window, no app launch — `RoundCheckbox.BoxButton` is drawn
/// off-screen into a bitmap the way the harness does it.
final class AllNotesBulkBarTests: XCTestCase {
    // MARK: - AllNotesBulkAction.bar

    @MainActor func testActiveWritableBarLeadsWithArchiveAndEndsWithClear() {
        let bar = AllNotesBulkAction.bar(archived: false, readOnly: false, allPinned: false)
        let expected: [AllNotesBulkAction] = [.archive, .pin, .colour, .font, .export, .reveal, .clear]
        XCTAssertEqual(bar.map(\.id), expected.map(\.id))
    }

    @MainActor func testActiveWritableBarOffersUnpinWhenEveryCheckedNoteIsPinned() {
        let bar = AllNotesBulkAction.bar(archived: false, readOnly: false, allPinned: true)
        let expected: [AllNotesBulkAction] = [.archive, .unpin, .colour, .font, .export, .reveal, .clear]
        XCTAssertEqual(bar.map(\.id), expected.map(\.id))
    }

    @MainActor func testArchivedWritableBarLeadsWithRestoreAndOffersDelete() {
        let bar = AllNotesBulkAction.bar(archived: true, readOnly: false, allPinned: false)
        let expected: [AllNotesBulkAction] = [.restore, .export, .reveal, .delete, .clear]
        XCTAssertEqual(bar.map(\.id), expected.map(\.id))
    }

    @MainActor func testDeleteOnlyEverAppearsUnderArchived() {
        XCTAssertFalse(AllNotesBulkAction.bar(archived: false, readOnly: false, allPinned: false).contains(.delete))
        XCTAssertTrue(AllNotesBulkAction.bar(archived: true, readOnly: false, allPinned: false).contains(.delete))
    }

    @MainActor func testReadOnlyBarIsExportRevealClearRegardlessOfScopeOrPinned() {
        let expected = [AllNotesBulkAction.export, .reveal, .clear].map(\.id)
        XCTAssertEqual(AllNotesBulkAction.bar(archived: false, readOnly: true, allPinned: false).map(\.id), expected)
        XCTAssertEqual(AllNotesBulkAction.bar(archived: false, readOnly: true, allPinned: true).map(\.id), expected)
        XCTAssertEqual(AllNotesBulkAction.bar(archived: true, readOnly: true, allPinned: false).map(\.id), expected)
        XCTAssertEqual(AllNotesBulkAction.bar(archived: true, readOnly: true, allPinned: true).map(\.id), expected)
    }

    @MainActor func testChipTitlesAreTheEllipsisAndShortReveal() {
        XCTAssertEqual(AllNotesBulkAction.reveal.title, "Reveal")
        XCTAssertEqual(AllNotesBulkAction.export.title, "Export…")
        XCTAssertEqual(AllNotesBulkAction.delete.title, "Delete…")
        XCTAssertEqual(AllNotesBulkAction.colour.title, "Colour")
    }

    // MARK: - RoundCheckbox.State.symbolName

    @MainActor func testSymbolNamesAreTheCircleFamilyNeverAnArrow() {
        XCTAssertEqual(RoundCheckbox.State.off.symbolName, "circle")
        XCTAssertEqual(RoundCheckbox.State.on.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(RoundCheckbox.State.mixed.symbolName, "minus.circle.fill")
    }

    // MARK: - RoundCheckboxGlyph.image

    @MainActor func testImageIsNonEmptySizedForEveryStateInLightAndDark() {
        for state: RoundCheckbox.State in [.off, .on, .mixed] {
            for dark in [false, true] {
                let image = RoundCheckboxGlyph.image(state: state, dark: dark)
                XCTAssertGreaterThan(image.size.width, 0, "\(state) dark:\(dark)")
                XCTAssertGreaterThan(image.size.height, 0, "\(state) dark:\(dark)")
            }
        }
    }

    // MARK: - RoundCheckboxGlyph.frame

    @MainActor func testFrameCentresTheImageOnA16By16Box() {
        let image = NSImage(size: NSSize(width: 15, height: 15))
        let bounds = CGRect(x: 0, y: 0, width: RoundCheckboxGlyph.side, height: RoundCheckboxGlyph.side)
        let frame = RoundCheckboxGlyph.frame(of: image, in: bounds)
        XCTAssertEqual(frame.midX, bounds.midX)
        XCTAssertEqual(frame.midY, bounds.midY)
        XCTAssertEqual(frame.width, 15)
        XCTAssertEqual(frame.height, 15)
    }

    // MARK: - The drawn control, pixel by pixel

    /// `RoundCheckbox.BoxButton` drawn into a 2× bitmap with no window —
    /// `NSGraphicsContext(bitmapImageRep:)`, the way `PreviewHarness`
    /// captures the same control. 0.1.2 drew the tick as its own
    /// `NSBezierPath` with y up in a flipped view, so the vertex landed
    /// at the top: an up-chevron. This proves the checked glyph the
    /// control actually draws has its vertex at the bottom, not the top.
    @MainActor private func renderOnStateCheckbox() throws -> NSBitmapImageRep {
        let side = RoundCheckboxGlyph.side
        let button = RoundCheckbox.BoxButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
        button.isBordered = false
        button.title = ""
        button.boxState = .on
        button.appearance = NSAppearance(named: .aqua)
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side * scale),
            pixelsHigh: Int(side * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = button.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        button.bounds.fill()
        button.displayIgnoringOpacity(button.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor func testCheckedGlyphsVertexSitsBelowCentreAndLeftOfCentreNotAtTheTopLikeAChevron() throws {
        let rep = try renderOnStateCheckbox()
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        // The central 60%: inside the coral circle, never the canvas the
        // bitmap was filled white with before the control drew over it.
        let x0 = Int(CGFloat(width) * 0.2), x1 = Int(CGFloat(width) * 0.8)
        let y0 = Int(CGFloat(height) * 0.2), y1 = Int(CGFloat(height) * 0.8)
        var markPixels: [(x: Int, y: Int)] = []
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.redComponent > 0.9, color.greenComponent > 0.9, color.blueComponent > 0.9 {
                    markPixels.append((x, y))
                }
            }
        }
        XCTAssertFalse(markPixels.isEmpty, "expected near-white checkmark pixels inside the coral circle")
        // colorAt(x:y:) is top-down, so the mark's lowest point on screen
        // is the pixel with the largest y.
        let vertex = try XCTUnwrap(markPixels.max(by: { $0.y < $1.y }))
        let centreX = CGFloat(width) / 2
        let centreY = CGFloat(height) / 2
        XCTAssertGreaterThan(CGFloat(vertex.y), centreY, "the vertex sits below the vertical centre; a chevron would put it at the top")
        XCTAssertLessThan(CGFloat(vertex.x), centreX, "the vertex sits left of centre: the left arm is the short one, the right arm the long one")
    }

    // MARK: - Bar visibility follows the checked set

    @MainActor func testSelectionEmptiesOnToggleOffKeepAndClear() {
        let a = NoteID("a"), b = NoteID("b")
        var selection = AllNotesSelection()
        XCTAssertTrue(selection.isEmpty)
        selection.toggle(a)
        XCTAssertFalse(selection.isEmpty)
        selection.toggle(a)
        XCTAssertTrue(selection.isEmpty, "toggling the same row back off")
        selection.toggle(b)
        XCTAssertFalse(selection.isEmpty)
        // A narrower search drops every checked row from view.
        selection.keep([])
        XCTAssertTrue(selection.isEmpty, "keep([]) with nothing on view")
        selection.toggle(a)
        selection.toggle(b)
        XCTAssertFalse(selection.isEmpty)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }

    @MainActor func testSessionClearSelectionEmptiesTheCheckedSetAndTheNotice() {
        let session = AllNotesSession()
        session.selected.toggle(NoteID("a"))
        session.show(.trashed(count: 1, urls: []))
        XCTAssertFalse(session.selected.isEmpty)
        XCTAssertNotNil(session.notice)
        session.clearSelection()
        XCTAssertTrue(session.selected.isEmpty)
        XCTAssertNil(session.notice)
    }

    /// The view raises the bar on `session.selected.ordered(in: visible)`
    /// being non-empty, not on `selection.isEmpty` — a row can stay
    /// checked in the set after it leaves view (a narrower search that
    /// hasn't run `keep` yet), and that checked-but-off-screen row must
    /// not hold the bar up.
    @MainActor func testBarVisibilityIsOrderedInVisibleNotJustWhetherAnythingIsChecked() {
        let onScreen = NoteID("a"), offScreen = NoteID("b")
        var selection = AllNotesSelection()
        selection.toggle(offScreen)
        XCTAssertFalse(selection.isEmpty, "still checked")
        XCTAssertTrue(selection.ordered(in: [onScreen]).isEmpty, "not on view: the bar stays down")
        selection.toggle(onScreen)
        XCTAssertFalse(selection.ordered(in: [onScreen]).isEmpty, "on view: the bar comes up")
        XCTAssertEqual(selection.ordered(in: [onScreen]), [onScreen], "the off-screen id never reaches the bar")
    }
}
