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
        XCTAssertEqual(sut.state, .pill)
        XCTAssertEqual(sut.handle(.timerFired(.hoverOpen)), [.showFan])
        XCTAssertEqual(sut.state, .fan)
        // Into the deck's content, then out of everything: the close timer.
        XCTAssertEqual(sut.handle(.pointerEnteredDeck), [])
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [])
        XCTAssertEqual(sut.handle(.pointerLeftDeck), [.startTimer(.hoverClose, 0.35)])
        // Back in before it fires: cancelled.
        XCTAssertEqual(sut.handle(.pointerEnteredDeck), [.cancelTimer(.hoverClose)])
        XCTAssertEqual(sut.handle(.pointerLeftDeck), [.startTimer(.hoverClose, 0.35)])
        XCTAssertEqual(sut.handle(.timerFired(.hoverClose)), [.showPill])
        XCTAssertEqual(sut.state, .pill)
    }

    @MainActor func testLeavingTheEdgeBeforeTheDelayCancelsTheFan() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        XCTAssertEqual(sut.handle(.pointerLeftEdge), [.cancelTimer(.hoverOpen)])
        XCTAssertEqual(sut.handle(.timerFired(.hoverOpen)), [])
        XCTAssertEqual(sut.state, .pill)
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

    @MainActor func testEscapeSavesAndSlidesBackToTheFanOrThePill() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabClicked(a))
        // Pointer still on the deck: back to the fan.
        XCTAssertEqual(sut.handle(.escape), [.closeNote(a), .showFan])
        XCTAssertEqual(sut.state, .fan)
        XCTAssertEqual(sut.handle(.escape), [.showPill])
        XCTAssertEqual(sut.state, .pill)
        // Pointer gone: straight to the pill.
        _ = sut.handle(.pointerLeftEdge)
        _ = sut.handle(.openRequested(b))
        XCTAssertEqual(sut.handle(.escape), [.closeNote(b), .showPill])
    }

    @MainActor func testAClickOutsideClosesEverything() {
        var sut = machine()
        _ = sut.handle(.openRequested(a))
        XCTAssertEqual(sut.handle(.clickedOutside), [.closeNote(a), .showPill])
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        XCTAssertEqual(sut.handle(.clickedOutside), [.showPill])
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
        XCTAssertEqual(sut.handle(.timerFired(.hoverClose)), [.showPill])
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
        XCTAssertEqual(sut.handle(.closeRequested), [.closeNote(c), .showPill])
        XCTAssertEqual(sut.state, .pill)
        XCTAssertEqual(sut.handle(.closeRequested), [])
    }

    @MainActor func testArchiveClosesSavesAndLeavesTheDeck() {
        var sut = machine()
        _ = sut.handle(.openRequested(b))
        XCTAssertEqual(sut.handle(.archiveRequested), [.closeNote(b), .archive(b), .showPill])
        XCTAssertEqual(sut.order, [a, c])
        XCTAssertEqual(sut.handle(.archiveRequested), [])
    }

    @MainActor func testTheOpenNoteLeavingTheDeckElsewhereClosesIt() {
        var sut = machine()
        _ = sut.handle(.openRequested(b))
        XCTAssertEqual(sut.handle(.notesChanged([a, c])), [.closeNote(b), .showPill])
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

    @MainActor func testHostLostSavesAndRestsAtThePill() {
        var sut = machine()
        _ = sut.handle(.pointerEnteredEdge)
        _ = sut.handle(.timerFired(.hoverOpen))
        _ = sut.handle(.tabClicked(a))
        _ = sut.handle(.pointerLeftEdge)
        XCTAssertEqual(sut.handle(.hostLost), [.closeNote(a), .showPill])
        XCTAssertEqual(sut.state, .pill)
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

/// Where the pill, the tabs and the note go, for both edges.
final class DeckGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let ids = (0..<3).map { NoteID("n\($0)") }

    @MainActor func testThePillHugsTheRightEdgeAndIsCentred() {
        let layout = DeckGeometry.layout(state: .pill, side: .right, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.panelFrame.maxX, screen.maxX)
        XCTAssertEqual(layout.panelFrame.midY, screen.midY, accuracy: 1)
        XCTAssertEqual(layout.pill.maxX, layout.panelFrame.width)
        XCTAssertEqual(layout.pill.width, 14)
        XCTAssertNil(layout.note)
        XCTAssertEqual(layout.tabs.count, 3)
    }

    @MainActor func testTheLeftEdgeMirrors() {
        let layout = DeckGeometry.layout(state: .open(ids[0], editing: true), side: .left, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.panelFrame.minX, screen.minX)
        XCTAssertEqual(layout.pill.minX, 0)
        XCTAssertEqual(layout.tabs[0].frame.minX, 0)
        XCTAssertEqual(layout.note?.minX, 40 + 8)
        XCTAssertEqual(layout.note?.width, 320)
        XCTAssertEqual(layout.note?.height, 360)
    }

    @MainActor func testTheFanShinglesDownFromTheTopWithThePlusUnderneath() {
        let layout = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.tabs.map(\.id), ids)
        XCTAssertEqual(layout.tabs[0].frame.maxY, layout.panelFrame.height - 24)
        XCTAssertEqual(layout.tabs[0].frame.minY - layout.tabs[1].frame.minY, 112 - 24)
        XCTAssertEqual(layout.tabs[1].frame.minY - layout.tabs[2].frame.minY, 112 - 24)
        XCTAssertEqual(layout.plusTab.maxY, layout.tabs[2].frame.minY - 8)
        XCTAssertGreaterThanOrEqual(layout.plusTab.minY, 0)
        XCTAssertEqual(layout.panelFrame.width, 40 + 24)
    }

    @MainActor func testMoreThanEightNotesGetAMoreTab() {
        let many = (0..<12).map { NoteID("n\($0)") }
        let layout = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: many)
        XCTAssertEqual(layout.tabs.count, 9)
        XCTAssertNil(layout.tabs[8].id)
        XCTAssertEqual(layout.tabs[8].more, 4)
        XCTAssertEqual(layout.tabs.dropLast().compactMap(\.id), Array(many.prefix(8)))
    }

    @MainActor func testTheToastWidensTheDeckAndSitsUnderIt() {
        let layout = DeckGeometry.layout(state: .pill, side: .right, visibleFrame: screen, notes: ids, toast: true)
        XCTAssertEqual(layout.panelFrame.width, 260 + 24)
        XCTAssertEqual(layout.toast?.minY, 24)
        XCTAssertEqual(layout.toast?.maxX, layout.panelFrame.width)
        XCTAssertEqual(layout.pill.maxX, layout.panelFrame.width)
        XCTAssertGreaterThan(layout.pill.minY, layout.toast?.maxY ?? 0)
        XCTAssertNil(DeckGeometry.layout(state: .pill, side: .right, visibleFrame: screen, notes: ids).toast)
    }

    @MainActor func testNoNotesStillLeavesAPillAndAPlus() {
        let layout = DeckGeometry.layout(state: .fan, side: .right, visibleFrame: screen, notes: [])
        XCTAssertEqual(layout.tabs, [])
        XCTAssertEqual(layout.plusTab.maxY, layout.panelFrame.height - 24)
        let pill = DeckGeometry.layout(state: .pill, side: .right, visibleFrame: screen, notes: [])
        XCTAssertEqual(pill.pill.height, 96)
    }

    @MainActor func testTheOpenNoteSitsBesideTheTabsAndFitsTheScreen() {
        let layout = DeckGeometry.layout(state: .open(ids[1], editing: false), side: .right, visibleFrame: screen, notes: ids)
        XCTAssertEqual(layout.note?.maxX, layout.tabs[0].frame.minX - 8)
        XCTAssertEqual(layout.note?.maxY, layout.tabs[0].frame.maxY)
        XCTAssertEqual(layout.panelFrame.width, 40 + 8 + 320 + 24)
        XCTAssertLessThanOrEqual(layout.panelFrame.height, screen.height)
        // A short screen clamps the panel inside it.
        let short = DeckGeometry.layout(state: .open(ids[1], editing: false), side: .right, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 300), notes: ids)
        XCTAssertEqual(short.panelFrame.height, 300)
        XCTAssertEqual(short.panelFrame.minY, 0)
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
            folder: "~/Documents/OpenNotes", folderIsMissing: false, watching: true, activeCount: 3, archivedCount: 1, unsavedCount: 0,
            defaultFont: "Sans · 14 pt", defaultColor: "Random", autoArchiveDays: 30, deckState: "pill", hostedDisplays: ["Built-in Retina Display"]
        )
        let text = snapshot.text()
        XCTAssertEqual(text, """
        OpenNotes 0.1.0 (1000) · macOS 26.0
        Open at login: on
        Licensing: off (source build) · read-only
        Deck: right edge · the main display · pill
        Displays hosting a deck: Built-in Retina Display
        Hotkey: ⌥⌘N (⌥⌘N is taken by another app.)
        Folder: ~/Documents/OpenNotes · watcher on
        Notes: 3 active · 1 archived · 0 unsaved
        Defaults: Sans · 14 pt · new notes Random · auto-archive after 30 days
        """)
    }
}
