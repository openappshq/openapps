import AppKit
import OpenNotesCore
import SwiftUI

/// One display's deck: a borderless non-activating `NSPanel` docked to the
/// screen edge, resized to the state's layout, its content the SwiftUI
/// `DeckView`. Every change goes through the core's `DeckStateMachine`;
/// this class owns the window, the timers and the monitors the machine's
/// effects ask for.
///
/// Over full-screen apps and Stage Manager (the spike in the implementation
/// report): the panel joins every Space and full-screen spaces
/// (`canJoinAllSpaces`, `fullScreenAuxiliary`), stays put through Exposé
/// (`stationary`), sits above the status bar level so a full-screen app's
/// window and Stage Manager's strip stay under it, and never activates
/// the app on its own (`nonactivatingPanel`): a click in the text makes
/// the panel key without bringing OpenNotes forward.
final class DeckPanelController {
    let displayID: CGDirectDisplayID
    private(set) var screen: NSScreen
    private let model: AppModel
    private let preferences: Preferences
    private let showAllNotes: () -> Void

    private(set) var machine: DeckStateMachine
    private let panel: NSPanel
    private let container: DeckContainerView
    private let hosting: NSHostingView<DeckView>
    private var timers: [DeckTimer: Timer] = [:]
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    /// The focus token for the current open (nil: opened without focus).
    private var focusToken: Int?
    private var focusCounter = 0
    /// Identities that moved while an effect list was being performed
    /// (a first-close rename, a conflict copy): later effects in the same
    /// list follow them.
    private var redirects: [NoteID: NoteID] = [:]
    /// The note whose body the deck holds retained: taken once per open,
    /// released once per close, moved with a redirect.
    private var held: NoteID?
    private var layout: DeckLayout
    /// While a tab is lifted: Escape reaches the deck through this, the
    /// panel made key for the duration (given back on the drop when it
    /// was not key before).
    private var dragKeyMonitor: Any?
    private var panelWasKeyBeforeDrag = false
    /// Bumped to put a lifted tab back (the view watches it).
    private var dragCancelToken = 0
    /// The note a drop or ⌥⌘↑/↓ is moving, for the announcement after.
    private var moving: NoteID?
    /// How far the fan is scrolled (clamped by the layout at each render).
    private var scroll: CGFloat = 0
    /// The tab to keep in view: the open note, else the last one used.
    private var keep: NoteID?
    /// Set when `keep` changed or the fan opened: the next render scrolls
    /// so the kept tab shows, and then leaves the scroll to the user.
    private var revealPending = false
    /// Something held over the pill or the fan (`DeckDrop`): the pill
    /// lights up as a target, or the deck says why a drop is refused.
    private var dropHover: DropHover = .none
    /// The dropped items' text, handed to `.createNote` when the machine
    /// answers the `.dropped` event; nil for the hotkey and `+`.
    private var pendingDropText: String?
    /// A drop made its note (set while the `.dropped` event is handled).
    private var dropMadeNote = false

    private enum DropHover: Equatable {
        case none
        case target
        case refused(String)

        var refusal: String? {
            if case .refused(let notice) = self { return notice }
            return nil
        }
    }

    /// The window level: above the status bar, so a full-screen app's
    /// window and the system's edge strips stay under the deck.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    var state: DeckState { machine.state }
    var isOpen: Bool { machine.isOpen }

    init(displayID: CGDirectDisplayID, screen: NSScreen, model: AppModel, preferences: Preferences, showAllNotes: @escaping () -> Void) {
        self.displayID = displayID
        self.screen = screen
        self.model = model
        self.preferences = preferences
        self.showAllNotes = showAllNotes
        machine = DeckStateMachine(settings: DeckSettings(readOnly: model.readOnly), notes: model.deckOrder, pinned: model.pinnedIDs)
        layout = DeckGeometry.layout(state: .pill, side: preferences.side, visibleFrame: screen.visibleFrame, notes: model.deckOrder)

        panel = DeckPanel(contentRect: layout.panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.level
        panel.collectionBehavior = Self.collectionBehavior
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityLabel("OpenNotes deck")
        // Asked to be left out of screen captures while the setting says so;
        // `settingsChanged` follows the setting from then on.
        ScreenSharing.apply(to: panel, surface: .deck, hidden: preferences.hideFromScreenSharing)

        hosting = NSHostingView(rootView: DeckView(content: DeckContent(layout: layout, state: .pill, side: preferences.side, notes: [], openNote: nil, readOnly: false, readOnlyNotice: "", statusLine: "", pendingUndo: nil, folderMissing: false)))
        container = DeckContainerView(hosting: hosting)
        container.onEdgeEnter = { [weak self] in self?.handle(.pointerEnteredEdge) }
        container.onEdgeExit = { [weak self] in self?.handle(.pointerLeftEdge) }
        container.onDeckEnter = { [weak self] in self?.handle(.pointerEnteredDeck) }
        container.onDeckExit = { [weak self] in self?.handle(.pointerLeftDeck) }
        container.onScroll = { [weak self] in self?.scroll(by: $0) }
        container.onDragEntered = { [weak self] in self?.dragEntered($0) ?? [] }
        container.onDragExited = { [weak self] in self?.dragExited() }
        container.onDrop = { [weak self] in self?.drop($0) ?? false }
        panel.contentView = container

        render()
        panel.orderFrontRegardless()
    }

    deinit {
        MainActor.assumeIsolated {
            for timer in timers.values { timer.invalidate() }
            removeMonitors()
            endDrag()
            panel.orderOut(nil)
        }
    }

    // MARK: - Events

    func handle(_ event: DeckEvent) {
        // The hotkey, `+`, a dropped item, a lift, a drop and a keyboard
        // move decide by the license: asked at the action, never the copy
        // the machine took at the last settings change (LICENSING.md,
        // read-only).
        switch event {
        case .hotkey, .plusClicked, .dropped, .tabLifted, .tabDropped, .moveRequested:
            _ = machine.handle(.settingsChanged(DeckSettings(readOnly: model.readOnly)))
        default: break
        }
        switch event {
        case .tabDropped: moving = machine.dragging
        case .moveRequested(let id, _): moving = id
        default: break
        }
        let effects = machine.handle(event)
        if case .tabLifted = event, machine.dragging != nil { beginDrag() }
        for effect in effects { perform(effect) }
        if case .tabDropped = event { endDrag() }
        redirects = [:]
        moving = nil
        if !effects.isEmpty || isStateEvent(event) { render() }
    }

    /// The open note one slot up (−1) or down (+1) the deck: ⌥⌘↑ / ⌥⌘↓
    /// and VoiceOver's actions. A note not in the deck moves nowhere.
    func move(_ id: NoteID, by step: Int) {
        guard let index = machine.order.firstIndex(of: id) else { return }
        handle(.moveRequested(id, to: index + step))
    }

    /// The model moved a note's identity: the machine's state and order
    /// follow, and so do the effects still being performed.
    func noteRedirected(from: NoteID, to: NoteID) {
        redirects[from] = to
        if held == from { held = to }
        if keep == from { keep = to }
        _ = machine.handle(.noteRenamed(from: from, to: to))
        render()
    }

    private func current(_ id: NoteID) -> NoteID {
        var id = id
        var hops = 0
        while let next = redirects[id], hops < 8 {
            id = next
            hops += 1
        }
        return id
    }

    /// The screen was re-read (resolution, arrangement): the deck follows.
    func update(screen: NSScreen) {
        self.screen = screen
        render()
    }

    func settingsChanged() {
        handle(.settingsChanged(DeckSettings(readOnly: model.readOnly)))
        render()
    }

    /// "Keep notes out of screen sharing" changed: the panel follows. False
    /// when it cannot — a panel once hidden is never shown again
    /// (`ScreenSharing`) — and the host must make this deck anew.
    func applyScreenSharing() -> Bool {
        ScreenSharing.apply(to: panel, surface: .deck, hidden: preferences.hideFromScreenSharing)
    }

    // MARK: - Dropping

    /// Something draggable arrived over the pill or the fan. Items that
    /// make no note (an image, an empty string) are not a target. The
    /// license is asked as the drag arrives, like the hotkey at its press:
    /// read-only, the deck refuses and says why while the drag hovers.
    private func dragEntered(_ items: [DropPayload.Item]) -> NSDragOperation {
        guard DropPayload.noteText(for: items) != nil else {
            dragExited()
            return []
        }
        if model.readOnly {
            dropHover = .refused(model.readOnlyNotice)
            render()
            return []
        }
        dropHover = .target
        render()
        return DeckDrop.operation(for: items)
    }

    private func dragExited() {
        guard dropHover != .none else { return }
        dropHover = .none
        render()
    }

    /// The items were let go: one note with their text, opened with the
    /// caret at its end — the hotkey's own path (`.dropped` → `.createNote`
    /// → `.noteCreated`), the text handed over when the store answers.
    /// The license is asked again at the drop, by the controller and the
    /// machine both: a drag can hover across a deadline. True when a note
    /// was made.
    private func drop(_ items: [DropPayload.Item]) -> Bool {
        dropHover = .none
        guard let text = DropPayload.noteText(for: items) else {
            render()
            return false
        }
        pendingDropText = text
        dropMadeNote = false
        handle(.dropped)
        pendingDropText = nil
        return dropMadeNote
    }

    /// The notes changed anywhere: the order, the open note's text.
    func notesChanged() {
        let before = machine.order
        handle(.notesChanged(model.deckOrder, pinned: model.pinnedIDs))
        // The order changed elsewhere (All Notes' drag) with a note open:
        // its tab follows into view. Otherwise the scroll is the user's.
        if machine.order != before, machine.isOpen { revealPending = true }
        render()
    }

    func tearDown() {
        handle(.hostLost)
        panel.orderOut(nil)
    }

    private func isStateEvent(_ event: DeckEvent) -> Bool {
        switch event {
        case .editorFocused, .settingsChanged, .notesChanged, .noteRenamed: true
        default: false
        }
    }

    private func perform(_ effect: DeckEffect) {
        switch effect {
        case .startTimer(let kind, let delay):
            timers[kind]?.invalidate()
            timers[kind] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.timerFired(kind)) }
            }
        case .cancelTimer(let kind):
            timers[kind]?.invalidate()
            timers[kind] = nil
        case .showPill, .showFan:
            removeMonitors()
            if panel.isKeyWindow { panel.resignKey() }
            model.clearConflictNotice()
            if effect == .showFan { revealPending = true }
        case .openNote(let id, let focus):
            if let held, held != id { model.release(held) }
            if held != id { model.retain(id) }
            held = id
            keep = id
            revealPending = true
            installMonitors()
            if focus {
                focusCounter += 1
                focusToken = focusCounter
                panel.makeKey()
            } else {
                focusToken = nil
            }
        case .focusNote:
            focusCounter += 1
            focusToken = focusCounter
            panel.makeKey()
        case .closeNote(let id):
            let id = current(id)
            let kept = model.closeNote(id)
            if let held, held == id || held == kept {
                model.release(kept ?? held)
                self.held = nil
            }
            if kept == nil {
                _ = machine.handle(.notesChanged(model.deckOrder))
            }
        case .createNote:
            if let note = model.createNote() {
                // A drop's text goes in before the note opens, so the
                // caret lands after it; the hotkey and `+` carry none.
                if let text = pendingDropText {
                    pendingDropText = nil
                    model.setText(text, for: note.id)
                    dropMadeNote = true
                }
                handle(.noteCreated(note.id))
            }
        case .archive(let id):
            model.archive(current(id))
            _ = machine.handle(.notesChanged(model.deckOrder, pinned: model.pinnedIDs))
        case .reorder(let ids):
            // The one write the All Notes list makes (`AppModel.reorder`:
            // asked at the drop, and again by the store at the file); the
            // machine's order follows what the store now says.
            let mover = moving
            let before = machine.order
            model.reorder(ids.map(current))
            _ = machine.handle(.notesChanged(model.deckOrder, pinned: model.pinnedIDs))
            // A note moved by the keyboard or VoiceOver may have left the
            // fan's window: the open note's tab is brought back into view.
            if machine.order != before, machine.isOpen { revealPending = true }
            if let mover, machine.order != before { announceMove(of: mover) }
        case .cancelDrag:
            dragCancelToken += 1
            endDrag()
        }
    }

    /// VoiceOver hears where the note went.
    private func announceMove(of moving: NoteID) {
        guard let note = model.note(current(moving)), let index = model.deckOrder.firstIndex(of: note.id) else { return }
        let text = "\(note.title) moved to position \(index + 1) of \(model.deckOrder.count)"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Dragging

    /// A tab lifted: Escape must reach the deck, so the panel is made key
    /// (without activating the app, as for the caret) and a local monitor
    /// takes the key; the fan itself is held out by the machine.
    private func beginDrag() {
        guard dragKeyMonitor == nil else { return }
        panelWasKeyBeforeDrag = panel.isKeyWindow
        if !panelWasKeyBeforeDrag { panel.makeKey() }
        dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.handle(.escape) }
            return nil
        }
    }

    private func endDrag() {
        guard let dragKeyMonitor else { return }
        NSEvent.removeMonitor(dragKeyMonitor)
        self.dragKeyMonitor = nil
        if !panelWasKeyBeforeDrag, panel.isKeyWindow { panel.resignKey() }
    }

    // MARK: - Rendering

    private func render() {
        let state = machine.state
        let notes = model.active
        let openNote = state.openNote.flatMap { model.body(of: $0) }
        let pending = model.pendingUndo
        // A refused drop's notice takes the toast's place under the deck.
        let refusal = dropHover.refusal
        let toast = pending != nil
        let notice = refusal != nil
        layout = DeckGeometry.layout(state: state, side: preferences.side, visibleFrame: screen.visibleFrame, notes: notes.map(\.id), toast: toast, notice: notice, scroll: scroll)
        scroll = layout.scroll
        // The open or last-used tab is brought into the fan once, when it
        // changed or the fan opened; the user's own scrolling is kept.
        if revealPending {
            revealPending = false
            if let keep = keep.map(current), let revealed = DeckGeometry.scroll(revealing: keep, in: layout), revealed != scroll {
                scroll = revealed
                layout = DeckGeometry.layout(state: state, side: preferences.side, visibleFrame: screen.visibleFrame, notes: notes.map(\.id), toast: toast, notice: notice, scroll: scroll)
            }
        }
        var content = DeckContent(
            layout: layout, state: state, side: preferences.side, notes: notes, openNote: openNote,
            readOnly: model.readOnly, readOnlyNotice: model.readOnlyNotice,
            statusLine: openNote.map { model.statusLine(for: $0.id) } ?? "",
            pendingUndo: pending, folderMissing: model.store.folderIsMissing, focusToken: focusToken,
            license: model.license
        )
        content.dropTarget = dropHover == .target
        content.dropRefusal = refusal
        content.progress = checklists(for: notes, state: state)
        // Every keystroke, paste and checkbox click asks the license as it
        // happens, not the `readOnly` this render captured — and that the
        // note's whole body is in memory: an editor showing a summary
        // (the body could not be read back) never edits.
        let openID = state.openNote
        content.mayEdit = { [weak model] in
            guard let model, !model.readOnly, let openID, let note = model.note(openID) else { return false }
            return note.bodyIsLoaded && !note.truncated
        }
        content.onTab = { [weak self] in self?.handle(.tabClicked($0)) }
        content.dragCancelToken = dragCancelToken
        content.onTabLifted = { [weak self] id in
            guard let self else { return false }
            self.handle(.tabLifted(id))
            return self.machine.dragging == id
        }
        content.onTabDropped = { [weak self] in self?.handle(.tabDropped(at: $0)) }
        content.onMove = { [weak self] id, step in self?.move(id, by: step) }
        content.onPlus = { [weak self] in self?.handle(.plusClicked) }
        content.onScroll = { [weak self] in self?.scroll(by: $0) }
        content.onTextChange = { [weak self] text in
            guard let self, let id = self.machine.state.openNote else { return }
            self.model.setText(text, for: id)
            // The tab's title follows the first line; the footer's status too.
            self.refreshContent()
        }
        content.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .escape: self.handle(.escape)
            case .next: self.handle(.closeRequested)
            // Archive writes the file: asked at the key, so a refused
            // archive never closes the note either.
            case .archive: if !self.model.readOnly { self.handle(.archiveRequested) }
            case .togglePin:
                if let id = self.machine.state.openNote, let note = self.model.note(id) { self.model.setPinned(!note.pinned, for: id) }
            case .toggleFace:
                if let id = self.machine.state.openNote, let note = self.model.note(id) { self.model.setFace(note.face.toggled, for: id) }
            case .moveUp:
                if let id = self.machine.state.openNote { self.move(id, by: -1) }
            case .moveDown:
                if let id = self.machine.state.openNote { self.move(id, by: 1) }
            }
        }
        content.onFocus = { [weak self] in self?.handle(.editorFocused) }
        content.onColor = { [weak self] color in
            guard let self, let id = self.machine.state.openNote else { return }
            self.model.setColor(color, for: id)
        }
        content.onFace = { [weak self] in
            guard let self, let id = self.machine.state.openNote, let note = self.model.note(id) else { return }
            self.model.setFace(note.face.toggled, for: id)
        }
        content.onPin = { [weak self] in
            guard let self, let id = self.machine.state.openNote, let note = self.model.note(id) else { return }
            self.model.setPinned(!note.pinned, for: id)
        }
        content.onArchive = { [weak self] in
            guard let self, !self.model.readOnly else { return }
            self.handle(.archiveRequested)
        }
        content.onUndo = { [weak self] in
            self?.model.undoArchive()
            self?.notesChanged()
        }
        content.onAllNotes = { [weak self] in self?.showAllNotes() }
        hosting.rootView = DeckView(content: content)
        container.edgeRect = edgeRect(in: layout)
        container.fanRect = fanHitRect(in: layout)
        container.deckRects = [container.fanRect, layout.plusTab] + [layout.note, layout.toast].compactMap { $0 }
        // A drop lands on the pill, or on the fan and its `+` tab; the open
        // note's text takes its own drops (the text view's), the margin none.
        container.dropRects = state == .pill ? [layout.pill] : [container.fanRect, layout.plusTab]
        moveWindow(to: layout.panelFrame)
    }

    /// The fan scrolled by `delta` points (positive: the tabs move up, what
    /// lies below comes into view): a wheel or trackpad over the fan, a
    /// drag on the deck's bare axis, ↑↓ with the deck focused, a lifted
    /// tab held at the fan's end. Clamped by the layout; no-op when
    /// everything fits.
    func scroll(by delta: CGFloat) {
        guard layout.maxScroll > 0 else { return }
        let next = min(max(scroll + delta, 0), layout.maxScroll)
        guard next != scroll else { return }
        scroll = next
        render()
    }

    /// The fan's column of tabs, the part the pointer and the wheel count
    /// as the deck (the fan itself spans the panel so shadows are not cut).
    private func fanHitRect(in layout: DeckLayout) -> CGRect {
        let metrics = DeckMetrics()
        let width = metrics.tabWidth + metrics.tiltInset + 6
        let x = preferences.side == .right ? layout.panelFrame.width - width : 0
        return CGRect(x: x, y: layout.fan.minY, width: width, height: layout.fan.height)
    }

    /// Only the content changed (typing): no new layout, no window move.
    private func refreshContent() {
        guard let id = machine.state.openNote, let note = model.note(id) else { return }
        var content = hosting.rootView.content
        content.openNote = note
        content.notes = model.active
        content.statusLine = model.statusLine(for: id)
        content.progress = checklists(for: content.notes, state: machine.state)
        hosting.rootView = DeckView(content: content)
    }

    /// The tabs' counts, from the model's cache: one parse per changed
    /// note, dictionary lookups otherwise. The pill has no tabs to count.
    private func checklists(for notes: [Note], state: DeckState) -> [NoteID: MarkdownLite.ChecklistProgress] {
        guard state != .pill else { return [:] }
        var result: [NoteID: MarkdownLite.ChecklistProgress] = [:]
        for note in notes {
            if let progress = model.checklistProgress(for: note.id) { result[note.id] = progress }
        }
        return result
    }

    /// The strip the pointer reaches at the screen edge: the pill's width
    /// over the deck's whole height, whatever the state.
    private func edgeRect(in layout: DeckLayout) -> CGRect {
        let width = DeckMetrics().pillWidth
        let x = preferences.side == .right ? layout.panelFrame.width - width : 0
        return CGRect(x: x, y: 0, width: width, height: layout.panelFrame.height)
    }

    private func moveWindow(to frame: CGRect) {
        guard panel.frame != frame else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Brand.Motion.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    // MARK: - Monitors

    /// While a note is open: a click anywhere else closes it (mouse
    /// buttons need no permission).
    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.clickedOutside) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.handle(.clickedOutside) }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }
}

/// A borderless panel cannot become key by default; the deck's must, so
/// the caret can go into a note without the app coming forward.
final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Holds the hosting view and reports the pointer entering and leaving
/// the edge strip and the deck's content, from tracking areas rebuilt
/// whenever the layout changes.
final class DeckContainerView: NSView {
    var onEdgeEnter: () -> Void = {}
    var onEdgeExit: () -> Void = {}
    var onDeckEnter: () -> Void = {}
    var onDeckExit: () -> Void = {}
    var edgeRect: CGRect = .zero {
        didSet { if edgeRect != oldValue { updateTrackingAreas() } }
    }
    var deckRects: [CGRect] = [] {
        didSet { if deckRects != oldValue { updateTrackingAreas() } }
    }
    /// The fan's column: a wheel or trackpad scroll over it, and ↑↓ while
    /// the deck has the keyboard, scroll the tabs.
    var fanRect: CGRect = .zero
    var onScroll: (CGFloat) -> Void = { _ in }
    /// Where a drop makes a note: the pill, or the fan and its `+` tab
    /// (`DeckDrop`). Elsewhere the drag passes as if the deck were not there.
    var dropRects: [CGRect] = []
    /// The drag arrived over a drop rect with these items: the operation
    /// to offer (none refuses it).
    var onDragEntered: ([DropPayload.Item]) -> NSDragOperation = { _ in [] }
    /// The drag left the drop rects, or ended.
    var onDragExited: () -> Void = {}
    /// The items were let go over a drop rect: true when a note was made.
    var onDrop: ([DropPayload.Item]) -> Bool = { _ in false }
    private var areas: [NSTrackingArea] = []
    private var insideEdge = false
    private var insideDeck = false
    private var insideDrop = false
    private var dragOperation: NSDragOperation = []
    private let hosting: NSView

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(DeckDrop.types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Drops

    /// Entering and moving are one rule: over a drop rect the controller
    /// is asked once (its answer kept while the drag stays), leaving it
    /// clears the target; nothing is re-asked per pointer move.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let inside = overDropRect(sender)
        if inside != insideDrop {
            insideDrop = inside
            if inside {
                dragOperation = onDragEntered(DeckDrop.items(from: sender.draggingPasteboard))
            } else {
                dragOperation = []
                onDragExited()
            }
        }
        return dragOperation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        leaveDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        leaveDrop()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        overDropRect(sender) && !dragOperation.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insideDrop = false
        dragOperation = []
        return onDrop(DeckDrop.items(from: sender.draggingPasteboard))
    }

    private func overDropRect(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        return dropRects.contains { $0.contains(point) }
    }

    private func leaveDrop() {
        guard insideDrop || !dragOperation.isEmpty else { return }
        insideDrop = false
        dragOperation = []
        onDragExited()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in areas { removeTrackingArea(area) }
        areas = []
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways]
        let edge = NSTrackingArea(rect: edgeRect, options: options, owner: self, userInfo: ["zone": "edge"])
        addTrackingArea(edge)
        areas.append(edge)
        for rect in deckRects {
            let area = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: ["zone": "deck"])
            addTrackingArea(area)
            areas.append(area)
        }
        // Rebuilt under the pointer: report where it is now.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            report(edge: edgeRect.contains(point), deck: deckRects.contains { $0.contains(point) })
        }
    }

    /// Natural scrolling: the tabs follow the fingers, so a positive delta
    /// (fingers moving down) shows what lies above. A wheel's line deltas
    /// are scaled to points.
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard fanRect.contains(point) else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        guard delta != 0 else { return }
        onScroll(-delta)
    }

    override var acceptsFirstResponder: Bool { true }

    /// ↑ / ↓ with the deck itself focused (no caret in a note): one tab.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == [.numericPad, .function] || flags == [.function] else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 126: onScroll(-DeckMetrics().tabStep)
        case 125: onScroll(DeckMetrics().tabStep)
        default: super.keyDown(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) { reportFromPointer(event) }
    override func mouseExited(with event: NSEvent) { reportFromPointer(event) }
    override func mouseMoved(with event: NSEvent) { reportFromPointer(event) }

    private func reportFromPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        report(edge: edgeRect.contains(point), deck: deckRects.contains { $0.contains(point) })
    }

    private func report(edge: Bool, deck: Bool) {
        if edge != insideEdge {
            insideEdge = edge
            edge ? onEdgeEnter() : onEdgeExit()
        }
        if deck != insideDeck {
            insideDeck = deck
            deck ? onDeckEnter() : onDeckExit()
        }
    }

    /// Clicks on the transparent margin fall through to what is under the
    /// panel; only the drawn parts take them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard edgeRect.contains(local) || deckRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}
