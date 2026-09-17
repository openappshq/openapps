import XCTest
@testable import OpenNotesCore

/// The deck's rules: hover fans, clicks open, Escape and ⌘W close and
/// save, the hotkey creates (or fans while read-only).
final class DeckStateMachineTests: XCTestCase {
    private let a = NoteID("a"), b = NoteID("b"), c = NoteID("c")

    private func machine(readOnly: Bool = false) -> DeckStateMachine {
        DeckStateMachine(settings: DeckSettings(readOnly: readOnly), notes: [a, b, c])
    }

    @MainActor func testHoverFansOutAfterTheDelayAndCollapsesAfterThePointerLeaves() {
        var sut = machine()
        XCTAssertEqual(sut.handle(.pointerEnteredEdge), [.startTimer(.hoverOpen, 0.12)])
        XCTAssertEqual(sut.state, .rest)
        XCTAssertEqual(sut.handle(.timerFired(.hoverOpen)), [.showFan])
        XCTAssertEqual(sut.state, .fan)
        // Into the deck's content, then out of everything: the close timer.
        XCTAssertEqual(sut.handle(.pointerEnteredDeck), [])
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [])
        XCTAssertEqual(sut.handle(.pointerLeftDeck), [.startTimer(.hoverClose, 0.35)])
        // Back in before it fires: cancelled.
        XCTAssertEqual(sut.handle(.pointerEnteredDeck), [.cancelTimer(.hoverClose)])
        XCTAssertEqual(sut.handle(.pointerLeftDeck), [.startTimer(.hoverClose, 0.35)])
        XCTAssertEqual(sut.handle(.timerFired(.hoverClose)), [.showRest])
        XCTAssertEqual(sut.state, .rest)
    }

    @MainActor func testLeavingTheEdgeBeforeTheDelayCancelsTheFan() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [.cancelTimer(.hoverOpen)])
        XCTAssertEqual(sut.handle(.timerFired(.hoverOpen)), [])
        XCTAssertEqual(sut.state, .rest)
    }

    @MainActor func testATabOpensTheNoteWithoutFocusAndItStaysOpenWhenThePointerLeaves() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.tabClicked(b)), [.openNote(b, focus: false)])
        XCTAssertEqual(sut.state, .open(b, editing: false))
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [])
        XCTAssertEqual(sut.handle(.pointerLeftDeck), [])
        XCTAssertEqual(sut.state, .open(b, editing: false))
        XCTAssertEqual(sut.handle(.editorFocused), [])
        XCTAssertEqual(sut.state, .open(b, editing: true))
        // Another tab: the first is saved and closed, the other opens.
        XCTAssertEqual(sut.handle(.tabClicked(c)), [.closeNote(b), .openNote(c, focus: false)])
        XCTAssertEqual(sut.handle(.tabClicked(c)), [])
        XCTAssertEqual(sut.handle(.tabClicked(NoteID("unknown"))), [])
    }

    @MainActor func testEscapeSavesAndSlidesBackToTheFanOrRest() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabClicked(a))
        // Pointer still on the deck: back to the fan.
        XCTAssertEqual(sut.handle(.escape), [.closeNote(a), .showFan])
        XCTAssertEqual(sut.state, .fan)
        XCTAssertEqual(sut.handle(.escape), [.showRest])
        XCTAssertEqual(sut.state, .rest)
        // Pointer gone: straight to rest.
        _ = sut.handle(.pointerLeftEdge)
        _ = sut.handle(.openRequested(b))
        XCTAssertEqual(sut.handle(.escape), [.closeNote(b), .showRest])
    }

    @MainActor func testAClickOutsideClosesEverything() {
        var sut = machine()
        _ = sut.handle(.openRequested(a))
        XCTAssertEqual(sut.handle(.clickedOutside), [.closeNote(a), .showRest])
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.clickedOutside), [.showRest])
        XCTAssertEqual(sut.handle(.clickedOutside), [])
    }

    @MainActor func testTheHotkeyCreatesANoteAndOpensItFocused() {
        var sut = machine()
        XCTAssertEqual(sut.handle(.hotkey), [.createNote])
        XCTAssertEqual(sut.state, .fan)
        let new = NoteID("new")
        XCTAssertEqual(sut.handle(.noteCreated(new)), [.openNote(new, focus: true)])
        XCTAssertEqual(sut.state, .open(new, editing: true))
        XCTAssertEqual(sut.order.first, new)
        // The hotkey again: the new note is saved, another is made.
        XCTAssertEqual(sut.handle(.hotkey), [.closeNote(new), .createNote])
    }

    @MainActor func testPlusIsTheHotkeyFromTheFan() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.plusClicked), [.createNote])
    }

    @MainActor func testReadOnlyHotkeyFansTheDeckInsteadOfCreating() {
        var sut = machine(readOnly: true)
        XCTAssertEqual(sut.handle(.hotkey), [.showFan, .startTimer(.hoverClose, 2)])
        XCTAssertEqual(sut.state, .fan)
        XCTAssertEqual(sut.handle(.timerFired(.hoverClose)), [.showRest])
        // With the pointer on it, it stays until the pointer leaves.
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.plusClicked), [.showFan])
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [.startTimer(.hoverClose, 0.35)])
        // Reading is still allowed.
        XCTAssertEqual(sut.handle(.tabClicked(a)), [.cancelTimer(.hoverClose), .openNote(a, focus: false)])
    }

    @MainActor func testCloseRequestedMovesToTheNextNoteThenBack() {
        var sut = machine()
        _ = sut.handle(.openRequested(a))
        XCTAssertEqual(sut.handle(.closeRequested), [.closeNote(a), .openNote(b, focus: true)])
        XCTAssertEqual(sut.handle(.closeRequested), [.closeNote(b), .openNote(c, focus: true)])
        XCTAssertEqual(sut.handle(.closeRequested), [.closeNote(c), .showRest])
        XCTAssertEqual(sut.state, .rest)
        XCTAssertEqual(sut.handle(.closeRequested), [])
    }

    @MainActor func testArchiveClosesSavesAndLeavesTheDeck() {
        var sut = machine()
        _ = sut.handle(.openRequested(b))
        XCTAssertEqual(sut.handle(.archiveRequested), [.closeNote(b), .archive(b), .showRest])
        XCTAssertEqual(sut.order, [a, c])
        XCTAssertEqual(sut.handle(.archiveRequested), [])
    }

    @MainActor func testTheOpenNoteLeavingTheDeckElsewhereClosesIt() {
        var sut = machine()
        _ = sut.handle(.openRequested(b))
        XCTAssertEqual(sut.handle(.notesChanged([a, c])), [.closeNote(b), .showRest])
        XCTAssertEqual(sut.order, [a, c])
        _ = sut.handle(.openRequested(c))
        XCTAssertEqual(sut.handle(.notesChanged([c, a])), [])
        XCTAssertEqual(sut.state, .open(c, editing: true))
    }

    @MainActor func testOpenRequestedFocusesEvenWhileAnotherNoteIsOpen() {
        var sut = machine()
        _ = sut.handle(.tabClicked(a))
        XCTAssertEqual(sut.handle(.openRequested(b)), [.closeNote(a), .openNote(b, focus: true)])
        // Already open: the caret only, never a second open (the deck's
        // hold on the note is taken once per open).
        XCTAssertEqual(sut.handle(.openRequested(b)), [.focusNote(b)])
        XCTAssertEqual(sut.handle(.openRequested(NoteID("nope"))), [])
    }

    @MainActor func testHostLostSavesAndReturnsToRest() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabClicked(a))
        _ = sut.handle(.pointerLeftEdge)
        XCTAssertEqual(sut.handle(.hostLost), [.closeNote(a), .showRest])
        XCTAssertEqual(sut.state, .rest)
        XCTAssertFalse(sut.pointerOnEdge)
        XCTAssertFalse(sut.pointerInDeck)
    }

    @MainActor func testSettingsChangeMidFlight() {
        var sut = machine()
        XCTAssertEqual(sut.handle(.settingsChanged(DeckSettings(hoverOpenDelay: 0.5, readOnly: true))), [])
        XCTAssertEqual(sut.handle(.pointerEnteredEdge), [.startTimer(.hoverOpen, 0.5)])
        XCTAssertEqual(sut.handle(.hotkey), [.cancelTimer(.hoverOpen), .showFan])
    }
}

/// Where the tabs and the note go, at rest and fanned, for both edges.
final class DeckGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let ids = (0..<3).map { NoteID("n\($0)") }

    @MainActor func testTheRestHugsTheRightEdgeAndIsCentred() {
        let layout = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.panelFrame.maxX, screen.maxX)
        XCTAssertEqual(layout.panelFrame.midY, screen.midY, accuracy: 1)
        XCTAssertEqual(layout.tabs[0].frame.maxX, layout.panelFrame.width, "tabs hug the edge")
        XCTAssertEqual(layout.tabs[0].frame.width, 8)
        XCTAssertEqual(layout.panelFrame.width, 8 + 24)
        XCTAssertNil(layout.note)
        XCTAssertEqual(layout.tabs.count, 3)
    }

    @MainActor func testTheLeftEdgeMirrors() {
        let layout = DeckGeometry.layout(state: .open(ids[0], editing: true), side: .left, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.panelFrame.minX, screen.minX)
        XCTAssertEqual(layout.tabs[0].frame.minX, 0)
        XCTAssertEqual(layout.note?.minX, 40 + 8)
        XCTAssertEqual(layout.note?.width, 320)
        XCTAssertEqual(layout.note?.height, 360)
    }

    @MainActor func testTheFanStacksDownFromTheTopWithThePlusUnderneath() {
        let layout = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.tabs.map(\.id), ids)
        XCTAssertEqual(layout.tabs[0].frame.maxY, layout.panelFrame.height - 24)
        // Separate papers: a 6 pt gap, never an overlap.
        XCTAssertEqual(layout.tabs[0].frame.minY - layout.tabs[1].frame.minY, 112 + 6)
        XCTAssertEqual(layout.tabs[1].frame.minY - layout.tabs[2].frame.minY, 112 + 6)
        XCTAssertEqual(layout.tabStep, 118)
        // Three fit: the fan is the whole stack, nothing scrolls, no fade.
        XCTAssertEqual(layout.fan.minY, layout.tabs[2].frame.minY)
        XCTAssertEqual(layout.maxScroll, 0)
        XCTAssertFalse(layout.canScrollUp)
        XCTAssertFalse(layout.canScrollDown)
        XCTAssertEqual(layout.plusTab.maxY, layout.fan.minY - 8)
        XCTAssertGreaterThanOrEqual(layout.plusTab.minY, 0)
        XCTAssertEqual(layout.panelFrame.width, 40 + 24)
    }

    @MainActor func testEveryNoteGetsATabAndWhatDoesNotFitScrollsUnderAFade() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let top = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        XCTAssertEqual(top.tabs.map(\.id), many, "no more-tab: every note has its own")
        XCTAssertLessThanOrEqual(top.panelFrame.height, screen.height)
        // The fan is what the screen leaves; the stack is taller.
        XCTAssertEqual(top.fan.height, screen.height - 2 * 24 - 40 - 8)
        XCTAssertEqual(top.maxScroll, 112 + 11 * 118 - top.fan.height)
        XCTAssertEqual(top.scroll, 0)
        XCTAssertFalse(top.canScrollUp)
        XCTAssertTrue(top.canScrollDown)
        XCTAssertLessThan(top.tabs[11].frame.maxY, top.fan.minY, "the last tab lies below the fan")
        XCTAssertEqual(top.plusTab.maxY, top.fan.minY - 8, "the plus tab is fixed under the fan")
        // Scrolled to the bottom: the last tab ends at the fan's bottom, the fade is above.
        let bottom = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, scroll: 10_000)
        XCTAssertEqual(bottom.scroll, bottom.maxScroll, "clamped")
        XCTAssertEqual(bottom.tabs[11].frame.minY, bottom.fan.minY, accuracy: 0.5)
        XCTAssertTrue(bottom.canScrollUp)
        XCTAssertFalse(bottom.canScrollDown)
        // Half way: both.
        let middle = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, scroll: top.maxScroll / 2)
        XCTAssertTrue(middle.canScrollUp)
        XCTAssertTrue(middle.canScrollDown)
        XCTAssertEqual(DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, scroll: -50).scroll, 0)
    }

    @MainActor func testTheOpenOrLastUsedTabIsScrolledIntoView() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let top = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        XCTAssertEqual(DeckGeometry.scroll(revealing: many[0], in: top), 0, "already in view: nothing moves")
        let reveal = try! XCTUnwrap(DeckGeometry.scroll(revealing: many[11], in: top))
        XCTAssertEqual(reveal, top.maxScroll, "the last tab: as little as needed, which is to the bottom")
        let bottom = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, scroll: reveal)
        XCTAssertEqual(DeckGeometry.scroll(revealing: many[0], in: bottom), 0)
        XCTAssertEqual(DeckGeometry.scroll(revealing: many[11], in: bottom), reveal)
        XCTAssertNil(DeckGeometry.scroll(revealing: NoteID("elsewhere"), in: top))
    }

    @MainActor func testEachTabLeansItsOwnStableWay() {
        let a = DeckTilt.tilt(for: NoteID("groceries"))
        XCTAssertEqual(a.degrees, DeckTilt.tilt(for: NoteID("groceries")).degrees, "seeded from the id: the same every time")
        XCTAssertEqual(a.inset, DeckTilt.tilt(for: NoteID("groceries")).inset)
        XCTAssertGreaterThanOrEqual(abs(a.degrees), 1.5)
        XCTAssertLessThanOrEqual(abs(a.degrees), 3)
        XCTAssertGreaterThanOrEqual(a.inset, 0)
        XCTAssertLessThanOrEqual(a.inset, 3)
        let tilts = (0..<40).map { DeckTilt.tilt(for: NoteID("note-\($0)")).degrees }
        XCTAssertTrue(tilts.contains { $0 > 0 } && tilts.contains { $0 < 0 }, "both ways across a deck")
    }

    @MainActor func testTheToastWidensTheDeckAndSitsUnderIt() {
        let layout = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids, toast: true)
        XCTAssertEqual(layout.panelFrame.width, 260 + 24)
        XCTAssertEqual(layout.toast?.minY, 24)
        XCTAssertEqual(layout.toast?.maxX, layout.panelFrame.width)
        XCTAssertEqual(layout.tabs[0].frame.maxX, layout.panelFrame.width, "tabs hug the edge")
        XCTAssertGreaterThan(layout.tabs[2].frame.minY, layout.toast?.maxY ?? 0, "the tabs, not a pill, sit above the toast")
        XCTAssertNil(DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: ids).toast)
    }

    @MainActor func testNoNotesStillLeavesTheEdgeAndAPlus() {
        let layout = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: [])
        XCTAssertEqual(layout.tabs, [])
        XCTAssertEqual(layout.plusTab.maxY, layout.panelFrame.height - 24)
        // An empty deck at rest is the `+` edge alone.
        let rest = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: [])
        XCTAssertEqual(rest.panelFrame.height, 40 + 48)
        XCTAssertEqual(rest.plusTab.width, 8)
        XCTAssertEqual(rest.plusTab.height, 40)
        XCTAssertEqual(rest.plusTab.maxY, rest.panelFrame.height - 24)
    }

    @MainActor func testTheOpenNoteSitsBesideTheTabsAndFitsTheScreen() {
        let layout = DeckGeometry.layout(state: .open(ids[1], editing: false), side: .right, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.note?.maxX, layout.tabs[0].frame.minX - 8)
        // ids[1]'s tab sits too high in this 3-note fan for the card's
        // full height to fit below it, so the card clamps to its minimum
        // height above the margin rather than top-aligning with the tab.
        XCTAssertEqual(layout.note?.maxY, 24 + 360)
        XCTAssertEqual(layout.panelFrame.width, 40 + 8 + 320 + 24)
        XCTAssertLessThanOrEqual(layout.panelFrame.height, screen.height)
        // A short screen clamps the panel inside it.
        let short = DeckGeometry.layout(state: .open(ids[1], editing: false), side: .right, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 300), notes: ids)
        XCTAssertEqual(short.panelFrame.height, 300)
        XCTAssertEqual(short.panelFrame.minY, 0)
    }

    // MARK: - Rest is the fan folded in

    @MainActor func testRestMatchesTheFanExceptTheTabWidthForBothEdges() {
        for side: DeckSide in [.right, .left] {
            let rest = DeckGeometry.layout(state: .rest, side: side, visibleFrame: screen, notes: ids)
            let fan = DeckGeometry.layout(state: .fan, side: side, visibleFrame: screen, notes: ids)
            // Same fan window vertically; its width follows the panel,
            // which is narrower at rest (the tabs are narrower).
            XCTAssertEqual(rest.fan.minY, fan.fan.minY, "\(side)")
            XCTAssertEqual(rest.fan.height, fan.fan.height, "\(side)")
            XCTAssertEqual(rest.scroll, fan.scroll, "\(side)")
            XCTAssertEqual(rest.maxScroll, fan.maxScroll, "\(side)")
            XCTAssertEqual(rest.plusTab.minY, fan.plusTab.minY, "\(side)")
            XCTAssertEqual(rest.tabStep, fan.tabStep, "\(side)")
            for i in ids.indices {
                XCTAssertEqual(rest.tabs[i].frame.minY, fan.tabs[i].frame.minY, "tab \(i), \(side)")
                XCTAssertEqual(rest.tabs[i].frame.maxY, fan.tabs[i].frame.maxY, "tab \(i), \(side)")
            }
            XCTAssertEqual(rest.tabs[0].frame.width, 8, "\(side)")
            XCTAssertEqual(fan.tabs[0].frame.width, 40, "\(side)")
            XCTAssertEqual(rest.panelFrame.width, 32, "\(side)")
            XCTAssertEqual(fan.panelFrame.width, 64, "\(side)")
            if side == .right {
                XCTAssertEqual(rest.panelFrame.maxX, screen.maxX)
                XCTAssertEqual(fan.panelFrame.maxX, screen.maxX)
            } else {
                XCTAssertEqual(rest.panelFrame.minX, screen.minX)
                XCTAssertEqual(fan.panelFrame.minX, screen.minX)
                XCTAssertEqual(rest.tabs[0].frame.minX, 0, "the left edge mirrors")
            }
        }
    }

    @MainActor func testRestScrollsAndFadesLikeTheFanWithTwelveNotes() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let rest = DeckGeometry.layout(state: .rest, side: .right, visibleFrame: screen, notes: many)
        let fan = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        XCTAssertEqual(rest.fan.minY, fan.fan.minY)
        XCTAssertEqual(rest.fan.height, fan.fan.height)
        XCTAssertEqual(rest.maxScroll, fan.maxScroll)
        XCTAssertEqual(rest.canScrollDown, fan.canScrollDown)
        XCTAssertTrue(rest.canScrollDown)
        XCTAssertEqual(rest.panelFrame.width, 32)
        for i in many.indices {
            XCTAssertEqual(rest.tabs[i].frame.minY, fan.tabs[i].frame.minY)
            XCTAssertEqual(rest.tabs[i].frame.maxY, fan.tabs[i].frame.maxY)
        }
    }

    // MARK: - A toast or notice takes room from the fan first

    @MainActor func testANoticeShrinksTheFanSoTheMessageNeverCoversThePlusTab() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let base = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        let withNotice = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, notice: true)
        XCTAssertEqual(base.fan.height - withNotice.fan.height, 58 + 8)
        XCTAssertGreaterThanOrEqual(withNotice.plusTab.minY, (withNotice.toast?.maxY ?? 0) + 8)
        XCTAssertLessThanOrEqual(withNotice.panelFrame.height, screen.height)
        XCTAssertEqual(withNotice.maxScroll - base.maxScroll, 58 + 8)
    }

    @MainActor func testAToastShrinksTheFanByItsOwnShorterHeight() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let base = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        let withToast = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, toast: true)
        XCTAssertEqual(base.fan.height - withToast.fan.height, 36 + 8)
        XCTAssertGreaterThanOrEqual(withToast.plusTab.minY, (withToast.toast?.maxY ?? 0) + 8)
        XCTAssertLessThanOrEqual(withToast.panelFrame.height, screen.height)
        XCTAssertEqual(withToast.maxScroll - base.maxScroll, 36 + 8)
    }

    @MainActor func testWithFewNotesTheFanAlreadyFitsSoTheNoticeShrinksNothing() {
        let base = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: ids)
        let withNotice = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: ids, notice: true)
        XCTAssertEqual(base.fan.height, withNotice.fan.height, "3 notes already fit: nothing to shrink")
        XCTAssertEqual(withNotice.maxScroll, 0)
        XCTAssertGreaterThan(withNotice.tabs[2].frame.minY, withNotice.toast?.maxY ?? 0, "the notice still sits under the deck")
    }

    // MARK: - The open note's card anchors to its tab

    @MainActor func testTheCardOverlapsItsTabAndStaysInThePanelHalfwayThroughAScrolledFan() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let reference = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        let scroll = reference.maxScroll / 2
        let layout = DeckGeometry.layout(state: .open(many[7], editing: false), side: .right, visibleFrame: screen, notes: many, scroll: scroll)
        let tab = try! XCTUnwrap(layout.tabs.first { $0.id == many[7] })
        let note = try! XCTUnwrap(layout.note)
        XCTAssertTrue(note.minY < tab.frame.maxY && note.maxY > tab.frame.minY, "the card overlaps its tab")
        XCTAssertGreaterThanOrEqual(note.minY, 24)
        XCTAssertLessThanOrEqual(note.maxY, layout.panelFrame.height - 24)
    }

    @MainActor func testTheCardTopAlignsWithTheFirstTabAtNoScroll() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let layout = DeckGeometry.layout(state: .open(many[0], editing: false), side: .right, visibleFrame: screen, notes: many, scroll: 0)
        let tab = try! XCTUnwrap(layout.tabs.first { $0.id == many[0] })
        XCTAssertEqual(layout.note?.maxY, tab.frame.maxY, "there's room below: the card top-aligns with its tab")
    }

    @MainActor func testTheCardClampsToThePanelBottomWhenItsTabIsScrolledToTheEndAndStillOverlapsIt() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let reference = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        let layout = DeckGeometry.layout(state: .open(many[11], editing: false), side: .right, visibleFrame: screen, notes: many, scroll: reference.maxScroll)
        let tab = try! XCTUnwrap(layout.tabs.first { $0.id == many[11] })
        let note = try! XCTUnwrap(layout.note)
        XCTAssertEqual(note.minY, 24, "clamped to the panel's bottom margin")
        XCTAssertTrue(note.minY < tab.frame.maxY && note.maxY > tab.frame.minY, "still overlaps its tab")
    }

    @MainActor func testACardWhoseTabIsScrolledOutOfViewClampsToTheFanThenToItsOwnMinimumHeight() {
        // many[11]'s tab, unscrolled, lies far below the fan's window (the
        // stack is taller than the fan): the anchor clamps up into the
        // fan first, then again to the card's own height above the
        // margin — past the point the card still touches the tab.
        let many = (0..<12).map { NoteID("n\($0)") }
        let layout = DeckGeometry.layout(state: .open(many[11], editing: false), side: .right, visibleFrame: screen, notes: many, scroll: 0)
        let tab = try! XCTUnwrap(layout.tabs.first { $0.id == many[11] })
        let note = try! XCTUnwrap(layout.note)
        XCTAssertLessThan(tab.frame.maxY, layout.fan.minY, "the tab is scrolled below the fan's window")
        XCTAssertEqual(note.maxY, 24 + 360)
        XCTAssertGreaterThan(note.minY, tab.frame.maxY, "the tab is scrolled too far for the card to reach it")
    }

    @MainActor func testTheCardsBottomNeverCoversTheToastEvenClampedToThePanelBottom() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let reference = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many, toast: true)
        let layout = DeckGeometry.layout(state: .open(many[11], editing: false), side: .right, visibleFrame: screen, notes: many, toast: true, scroll: reference.maxScroll)
        let note = try! XCTUnwrap(layout.note)
        let toast = try! XCTUnwrap(layout.toast)
        XCTAssertGreaterThanOrEqual(note.minY, toast.maxY + 8)
    }
}

/// A lifted tab held at the fan's edge scrolls it under itself
/// (design/products/opennotes.md, "Overflow scrolls").
final class DeckAutoScrollTests: XCTestCase {
    private let fan = CGRect(x: 0, y: 100, width: 64, height: 600)
    private let metrics = DeckMetrics()

    @MainActor func testDirectionIsUpWithinAQuarterTabOfTheFansTopOnlyWhenItCanScrollUp() {
        let centre: CGFloat = 100 + 56 + 10
        XCTAssertEqual(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: true, canScrollDown: true, metrics: metrics), .up)
        XCTAssertNil(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: false, canScrollDown: true, metrics: metrics))
    }

    @MainActor func testDirectionIsDownWithinAQuarterTabOfTheFansBottomOnlyWhenItCanScrollDown() {
        let centre: CGFloat = 700 - 56 - 10
        XCTAssertEqual(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: true, canScrollDown: true, metrics: metrics), .down)
        XCTAssertNil(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: true, canScrollDown: false, metrics: metrics))
    }

    @MainActor func testDirectionIsNilAwayFromEitherEndRegardlessOfWhatCanScroll() {
        let centre = fan.midY
        XCTAssertNil(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: true, canScrollDown: true, metrics: metrics))
        XCTAssertNil(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: false, canScrollDown: false, metrics: metrics))
    }

    @MainActor func testDirectionIsNilExactlyAtTheQuarterTabBoundary() {
        // The comparison is a strict `<`: right at the boundary, neither end claims it.
        let centre: CGFloat = fan.minY + 28 + metrics.tabHeight / 2
        XCTAssertNil(DeckAutoScroll.direction(tabCenterY: centre, fan: fan, canScrollUp: true, canScrollDown: true, metrics: metrics))
    }

    @MainActor func testDeltaMovesSixPointsEachWayAndTheIntervalIsAFrame() {
        XCTAssertEqual(DeckAutoScroll.delta(.up), -6)
        XCTAssertEqual(DeckAutoScroll.delta(.down), 6)
        XCTAssertEqual(DeckAutoScroll.interval, 1.0 / 60.0)
    }
}

/// When the edge-hold timer starts, restarts and stops (design/products/opennotes.md,
/// "Overflow scrolls"): pure, the view owns the timer itself.
final class DeckEdgeHoldTests: XCTestCase {
    @MainActor func testMovingToNilFromFreshIsNoneAndNotHolding() {
        var hold = DeckEdgeHold()
        XCTAssertEqual(hold.moved(to: nil), .none)
        XCTAssertFalse(hold.isHolding)
        XCTAssertNil(hold.direction)
    }

    @MainActor func testMovingToADirectionStartsHoldingAndRepeatingItChangesNothing() {
        var hold = DeckEdgeHold()
        XCTAssertEqual(hold.moved(to: .down), .start(.down))
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.direction, .down)
        XCTAssertEqual(hold.moved(to: .down), .none)
    }

    @MainActor func testMovingToTheOtherDirectionRestartsTheTimerThatWay() {
        var hold = DeckEdgeHold()
        _ = hold.moved(to: .down)
        XCTAssertEqual(hold.moved(to: .up), .start(.up))
        XCTAssertEqual(hold.direction, .up)
    }

    @MainActor func testMovingToNilWhileHoldingStopsIt() {
        var hold = DeckEdgeHold()
        _ = hold.moved(to: .up)
        XCTAssertEqual(hold.moved(to: nil), .stop)
        XCTAssertFalse(hold.isHolding)
        XCTAssertNil(hold.direction)
    }

    @MainActor func testEndedStopsOnlyWhileHoldingElseNone() {
        var holding = DeckEdgeHold()
        _ = holding.moved(to: .down)
        XCTAssertEqual(holding.ended(), .stop)
        XCTAssertFalse(holding.isHolding)

        var idle = DeckEdgeHold()
        XCTAssertEqual(idle.ended(), .none)
    }
}

/// Archive's 10-second undo, search and auto-archive: pure rules.
final class RulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    @MainActor func testUndoOffersTheLatestArchiveForTenSeconds() {
        var undo = ArchiveUndo()
        XCTAssertNil(undo.current(at: t0))
        undo.archived(NoteID("a"), title: "A", at: t0)
        undo.archived(NoteID("b"), title: "B", at: t0.addingTimeInterval(1))
        XCTAssertEqual(undo.current(at: t0.addingTimeInterval(2))?.id, NoteID("b"))
        XCTAssertEqual(undo.undo(at: t0.addingTimeInterval(2)), NoteID("b"))
        XCTAssertEqual(undo.undo(at: t0.addingTimeInterval(3)), NoteID("a"))
        XCTAssertNil(undo.undo(at: t0.addingTimeInterval(4)))
        undo.archived(NoteID("c"), title: "C", at: t0)
        XCTAssertNil(undo.current(at: t0.addingTimeInterval(10)))
        XCTAssertNil(undo.undo(at: t0.addingTimeInterval(10)))
        undo.archived(NoteID("d"), title: "D", at: t0)
        undo.forget(NoteID("d"))
        XCTAssertNil(undo.current(at: t0))
    }

    @MainActor func testSearchIsCaseAndDiacriticInsensitiveAndNeedsEveryWord() {
        let notes = [
            Note(id: NoteID("a"), text: "Café plans\n- croissants", created: t0),
            Note(id: NoteID("b"), text: "Standup\nask about the feed key", created: t0),
        ]
        XCTAssertEqual(Search.matches("cafe", in: notes).map(\.id.rawValue), ["a"])
        XCTAssertEqual(Search.matches("FEED key", in: notes).map(\.id.rawValue), ["b"])
        XCTAssertEqual(Search.matches("feed croissant", in: notes), [])
        XCTAssertEqual(Search.matches("   ", in: notes), notes)
    }

    @MainActor func testAutoArchivePicksUnpinnedNotesUntouchedForTheChosenDays() {
        let old = t0.addingTimeInterval(-31 * 86_400)
        let notes = [
            Note(id: NoteID("old"), text: "x", created: old, modified: old),
            Note(id: NoteID("pinned"), text: "x", pinned: true, created: old, modified: old),
            Note(id: NoteID("archived"), text: "x", archived: true, created: old, modified: old),
            Note(id: NoteID("fresh"), text: "x", created: old, modified: t0.addingTimeInterval(-86_400)),
        ]
        XCTAssertEqual(AutoArchive.candidates(in: notes, days: 30, now: t0), [NoteID("old")])
        XCTAssertEqual(AutoArchive.candidates(in: notes, days: 90, now: t0), [])
        XCTAssertEqual(AutoArchive.candidates(in: notes, days: 0, now: t0), [])
        XCTAssertEqual(AutoArchive.choices, [0, 7, 30, 90])
        XCTAssertEqual(AutoArchive.title(days: 0), "Off")
        XCTAssertEqual(AutoArchive.title(days: 7), "After 7 days")
    }

    @MainActor func testTheDefaultHotkeyIsOptionCommandN() {
        XCTAssertEqual(Hotkey.default.displayString, "⌥⌘N")
        XCTAssertTrue(Hotkey.default.isValid)
        XCTAssertFalse(Hotkey(keyCode: 12, modifiers: [.command]).isValid)
        XCTAssertEqual(Hotkey(keyCode: 45, modifiers: [.shift]).problem, "Use at least one of ⌘, ⌥ or ⌃.")
    }

    @MainActor func testDiagnosticsTextNamesEverything() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0 (1000)", macOSVersion: "26.0", loginStatus: "on", licensing: "off (source build)", readOnly: true,
            side: .right, display: .main, hotkey: .default, hotkeyProblem: "⌥⌘N is taken by another app.",
            folder: "~/Documents/OpenNotes", folderIsMissing: false, storage: "iCloud Drive · 2 not downloaded", watching: true, activeCount: 3, archivedCount: 1, unsavedCount: 0,
            defaultFont: "Sans · 14 pt", defaultColor: "Random", autoArchiveDays: 30, deckState: "rest", hostedDisplays: ["Built-in Retina Display"]
        )
        let text = snapshot.text()
        XCTAssertEqual(text, """
        OpenNotes 0.1.0 (1000) · macOS 26.0
        Open at login: on
        Licensing: off (source build) · read-only
        Deck: right edge · the main display · rest
        Displays hosting a deck: Built-in Retina Display
        Hotkey: ⌥⌘N (⌥⌘N is taken by another app.)
        Folder: ~/Documents/OpenNotes · iCloud Drive · 2 not downloaded · watcher on
        Notes: 3 active · 1 archived · 0 unsaved
        Defaults: Sans · 14 pt · new notes Random · auto-archive after 30 days
        """)
    }
}
