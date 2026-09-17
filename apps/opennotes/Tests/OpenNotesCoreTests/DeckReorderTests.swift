import XCTest
@testable import OpenNotesCore

/// Drag to reorder (design/products/opennotes.md, "The deck"): a lift
/// holds the fan out and cancels a pending close, a drop or ⌥⌘↑/⌥⌘↓ ask for
/// one `.reorder` inside the note's pinned or unpinned group, and Escape or
/// the note leaving the deck under the pointer puts a lifted tab back.
final class DeckReorderTests: XCTestCase {
    private let a = NoteID("a"), b = NoteID("b"), c = NoteID("c")

    private func machine(readOnly: Bool = false) -> DeckStateMachine {
        DeckStateMachine(settings: DeckSettings(readOnly: readOnly), notes: [a, b, c])
    }

    @MainActor func testTabLiftedSetsDraggingCancelsAPendingCloseAndScheduledNoneWhileHeld() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.state, .fan)
        _ = sut.handle(.pointerLeftEdge) // schedules a close timer
        XCTAssertEqual(sut.handle(.tabLifted(a)), [.cancelTimer(.hoverClose)])
        XCTAssertEqual(sut.dragging, a)
        XCTAssertEqual(sut.handle(.pointerLeftDeck), [], "no close is scheduled while a tab is held")
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [])
        XCTAssertEqual(sut.handle(.timerFired(.hoverClose)), [], "a stray fire changes nothing while dragging")
        XCTAssertEqual(sut.state, .fan)
    }

    @MainActor func testTabDroppedReordersAndTheOrderWaitsForTheStore() {
        var sut = machine()
        _ = sut.handle(.tabLifted(a))
        XCTAssertEqual(sut.handle(.tabDropped(at: 2)), [.reorder([b, c, a])])
        XCTAssertNil(sut.dragging)
        XCTAssertEqual(sut.order, [a, b, c], "the store's .notesChanged is the one write")
        _ = sut.handle(.notesChanged([b, c, a]))
        XCTAssertEqual(sut.order, [b, c, a])
    }

    @MainActor func testTabDroppedNowhereMakesNoReorder() {
        var sut = machine()
        _ = sut.handle(.tabLifted(a))
        XCTAssertEqual(sut.handle(.tabDropped(at: nil)), [])
        XCTAssertNil(sut.dragging)
    }

    @MainActor func testTabDroppedWithNoDragInFlightDoesNothing() {
        var sut = machine()
        XCTAssertEqual(sut.handle(.tabDropped(at: 1)), [])
    }

    @MainActor func testDroppingAfterThePointerLeftSchedulesTheCloseTimer() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabLifted(a))
        _ = sut.handle(.pointerLeftEdge)
        XCTAssertEqual(sut.handle(.tabDropped(at: 2)), [.reorder([b, c, a]), .startTimer(.hoverClose, 0.35)])
    }

    @MainActor func testMoveRequestedClampsToTheEndsAndDeduplicatesTrivialMoves() {
        var sut = machine()
        XCTAssertEqual(sut.handle(.moveRequested(a, to: 1)), [.reorder([b, a, c])])
        XCTAssertEqual(sut.handle(.moveRequested(a, to: 0)), [], "already first")
        XCTAssertEqual(sut.handle(.moveRequested(a, to: 99)), [.reorder([b, c, a])], "clamps to the end")
        XCTAssertEqual(sut.handle(.moveRequested(NoteID("gone"), to: 0)), [], "not in the order")
        var solo = DeckStateMachine(settings: DeckSettings(), notes: [a])
        XCTAssertEqual(solo.handle(.moveRequested(a, to: 5)), [], "nowhere else to go")
    }

    @MainActor func testPinnedNotesStayFirstAndAMoveNeverCrossesTheBoundary() {
        let p = NoteID("p")
        var sut = DeckStateMachine(settings: DeckSettings(), notes: [p, a, b], pinned: [p])
        XCTAssertEqual(sut.handle(.moveRequested(a, to: 0)), [], "clamps back to the unpinned group's edge")
        XCTAssertEqual(sut.handle(.moveRequested(b, to: 0)), [.reorder([p, b, a])])
        XCTAssertEqual(sut.handle(.moveRequested(p, to: 2)), [], "pinned alone in its group")
        // The same clamp through a drop.
        _ = sut.handle(.tabLifted(a))
        XCTAssertEqual(sut.handle(.tabDropped(at: 0)), [])
        _ = sut.handle(.tabLifted(b))
        XCTAssertEqual(sut.handle(.tabDropped(at: 0)), [.reorder([p, b, a])])
    }

    @MainActor func testDeckReorderClampsAndMovesDirectlyIncludingExtremeIndices() {
        let p = NoteID("p")
        let order = [p, a, b]
        let pinned: Set<NoteID> = [p]
        XCTAssertEqual(DeckReorder.clampedIndex(Int.min, for: a, in: order, pinned: pinned), 1)
        XCTAssertEqual(DeckReorder.clampedIndex(Int.max, for: a, in: order, pinned: pinned), 2)
        XCTAssertEqual(DeckReorder.clampedIndex(2, for: p, in: order, pinned: pinned), 0)
        XCTAssertNil(DeckReorder.clampedIndex(0, for: NoteID("gone"), in: order, pinned: pinned))
        XCTAssertNil(DeckReorder.moved(p, to: 0, in: order, pinned: pinned), "already there")
        XCTAssertEqual(DeckReorder.moved(a, to: 2, in: order, pinned: pinned), [p, b, a])
        XCTAssertNil(DeckReorder.moved(NoteID("gone"), to: 0, in: order, pinned: pinned))
    }

    @MainActor func testReadOnlyRefusesLiftingAndMoving() {
        var sut = machine(readOnly: true)
        XCTAssertEqual(sut.handle(.tabLifted(a)), [])
        XCTAssertNil(sut.dragging)
        XCTAssertEqual(sut.handle(.moveRequested(a, to: 1)), [])
    }

    @MainActor func testEscapeWhileDraggingCancelsTheDragOnly() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabLifted(a))
        XCTAssertEqual(sut.handle(.escape), [.cancelDrag])
        XCTAssertEqual(sut.state, .fan)
        XCTAssertNil(sut.dragging)
    }

    @MainActor func testEscapeWhileDraggingSchedulesACloseWhenThePointerIsOff() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabLifted(a))
        _ = sut.handle(.pointerLeftEdge)
        XCTAssertEqual(sut.handle(.escape), [.cancelDrag, .startTimer(.hoverClose, 0.35)])
        XCTAssertEqual(sut.state, .fan)
    }

    @MainActor func testEscapeWithNoDragStillCollapsesTheFanToRest() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.escape), [.showRest])
        XCTAssertEqual(sut.state, .rest)
    }

    @MainActor func testRenameDuringADragFollowsTheDraggedNote() {
        var sut = machine()
        _ = sut.handle(.tabLifted(a))
        let a2 = NoteID("a2")
        _ = sut.handle(.noteRenamed(from: a, to: a2))
        XCTAssertEqual(sut.dragging, a2)
        XCTAssertEqual(sut.handle(.tabDropped(at: 2)), [.reorder([b, c, a2])])
    }

    @MainActor func testPinnedSetFollowsARenameToo() {
        let p = NoteID("p")
        var sut = DeckStateMachine(settings: DeckSettings(), notes: [p, a, b], pinned: [p])
        let p2 = NoteID("p2")
        _ = sut.handle(.noteRenamed(from: p, to: p2))
        XCTAssertEqual(sut.pinned, [p2])
        XCTAssertEqual(sut.order, [p2, a, b])
    }

    @MainActor func testNotesChangedDroppingTheDraggedNoteCancelsTheDrag() {
        var sut = machine()
        _ = sut.handle(.tabLifted(a))
        XCTAssertEqual(sut.handle(.notesChanged([b, c])), [.cancelDrag])
        XCTAssertNil(sut.dragging)
        XCTAssertEqual(sut.order, [b, c])
    }

    @MainActor func testHostLostCancelsAnInFlightDrag() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabLifted(a))
        XCTAssertEqual(sut.handle(.hostLost), [.cancelDrag, .showRest])
        XCTAssertNil(sut.dragging)
        XCTAssertEqual(sut.state, .rest)
    }

    @MainActor func testNotesChangedCarriesThePinnedSetAndDefaultsToEmpty() {
        let p = NoteID("p")
        var sut = DeckStateMachine(settings: DeckSettings(), notes: [a, b, p])
        _ = sut.handle(.notesChanged([p, a, b], pinned: [p]))
        XCTAssertEqual(sut.pinned, [p])
        XCTAssertEqual(sut.handle(.moveRequested(p, to: 2)), [], "the new pinned group is respected")
        _ = sut.handle(.notesChanged([a, b, p]))
        XCTAssertEqual(sut.pinned, [], "the default keeps existing call sites working")
    }
}
