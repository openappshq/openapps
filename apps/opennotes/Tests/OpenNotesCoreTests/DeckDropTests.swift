import XCTest
@testable import OpenNotesCore

/// "Drop to create" (design/products/opennotes.md, "The deck"): `.dropped`
/// behaves exactly like `.hotkey` — closes an open note, makes a new one —
/// and while read-only fans the deck instead, making nothing.
final class DeckDropTests: XCTestCase {
    private let a = NoteID("a"), b = NoteID("b")

    private func machine(readOnly: Bool = false) -> DeckStateMachine {
        DeckStateMachine(settings: DeckSettings(readOnly: readOnly), notes: [a, b])
    }

    @MainActor func testDroppedAtRestCreatesANoteAndLeavesTheStateFanned() {
        var sut = machine()
        XCTAssertEqual(sut.state, .rest)
        XCTAssertEqual(sut.handle(.dropped), [.createNote])
        XCTAssertEqual(sut.state, .fan)
    }

    @MainActor func testDroppedOnAnOpenNoteClosesItFirst() {
        var sut = machine()
        _ = sut.handle(.openRequested(a))
        XCTAssertEqual(sut.handle(.dropped), [.closeNote(a), .createNote])
        XCTAssertEqual(sut.state, .fan)
    }

    @MainActor func testDroppedWhileReadOnlyFansTheDeckAndCreatesNothing() {
        var sut = machine(readOnly: true)
        XCTAssertEqual(sut.handle(.dropped), [.showFan, .startTimer(.hoverClose, 2)])
        XCTAssertEqual(sut.state, .fan)
    }

    @MainActor func testDroppedWhileReadOnlyWithThePointerOnTheDeckStaysUntilItLeaves() {
        var sut = machine(readOnly: true)
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.dropped), [.showFan], "the pointer is already here: no close timer")
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [.startTimer(.hoverClose, 0.35)])
    }

    @MainActor func testNoteCreatedAfterADropOpensItFocused() {
        var sut = machine()
        _ = sut.handle(.dropped)
        let new = NoteID("dropped-note")
        XCTAssertEqual(sut.handle(.noteCreated(new)), [.openNote(new, focus: true)])
        XCTAssertEqual(sut.state, .open(new, editing: true))
        XCTAssertEqual(sut.order.first, new)
    }
}

/// The archive toast's rect widens for the taller notice a refused drop
/// shows in its place (design/products/opennotes.md, "Drop to create"):
/// `notice: true` always wins over `toast: true` alone.
final class DeckDropNoticeLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let ids = (0..<3).map { NoteID("n\($0)") }
    private let metrics = DeckMetrics()

    @MainActor func testNoticeGivesTheToastRectTheNoticeHeightAndGrowsThePanel() {
        let base = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids)
        let withNotice = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids, notice: true)
        XCTAssertEqual(withNotice.toast?.height, metrics.noticeHeight)
        XCTAssertEqual(withNotice.panelFrame.height, base.panelFrame.height + metrics.gap + metrics.noticeHeight)
    }

    @MainActor func testToastAloneGivesTheToastHeight() {
        let base = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids)
        let withToast = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids, toast: true)
        XCTAssertEqual(withToast.toast?.height, metrics.toastHeight)
        XCTAssertEqual(withToast.panelFrame.height, base.panelFrame.height + metrics.gap + metrics.toastHeight)
    }

    @MainActor func testNoticeWinsWhenBothAreRequested() {
        let both = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids, toast: true, notice: true)
        XCTAssertEqual(both.toast?.height, metrics.noticeHeight)
    }

    @MainActor func testNeitherLeavesNoToastRect() {
        let neither = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids)
        XCTAssertNil(neither.toast)
    }
}
