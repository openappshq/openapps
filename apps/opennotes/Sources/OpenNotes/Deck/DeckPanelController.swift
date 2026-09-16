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
    private var layout: DeckLayout

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
        machine = DeckStateMachine(settings: DeckSettings(readOnly: model.readOnly), notes: model.deckOrder)
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

        hosting = NSHostingView(rootView: DeckView(content: DeckContent(layout: layout, state: .pill, side: preferences.side, notes: [], openNote: nil, readOnly: false, readOnlyNotice: "", statusLine: "", pendingUndo: nil, folderMissing: false)))
        container = DeckContainerView(hosting: hosting)
        container.onEdgeEnter = { [weak self] in self?.handle(.pointerEnteredEdge) }
        container.onEdgeExit = { [weak self] in self?.handle(.pointerLeftEdge) }
        container.onDeckEnter = { [weak self] in self?.handle(.pointerEnteredDeck) }
        container.onDeckExit = { [weak self] in self?.handle(.pointerLeftDeck) }
        panel.contentView = container

        render()
        panel.orderFrontRegardless()
    }

    deinit {
        MainActor.assumeIsolated {
            for timer in timers.values { timer.invalidate() }
            removeMonitors()
            panel.orderOut(nil)
        }
    }

    // MARK: - Events

    func handle(_ event: DeckEvent) {
        let effects = machine.handle(event)
        for effect in effects { perform(effect) }
        redirects = [:]
        if !effects.isEmpty || isStateEvent(event) { render() }
    }

    /// The model moved a note's identity: the machine's state and order
    /// follow, and so do the effects still being performed.
    func noteRedirected(from: NoteID, to: NoteID) {
        redirects[from] = to
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

    /// The notes changed anywhere: the order, the open note's text.
    func notesChanged() {
        handle(.notesChanged(model.deckOrder))
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
        case .openNote(_, let focus):
            installMonitors()
            if focus {
                focusCounter += 1
                focusToken = focusCounter
                panel.makeKey()
            } else {
                focusToken = nil
            }
        case .closeNote(let id):
            let id = current(id)
            if model.closeNote(id) == nil {
                _ = machine.handle(.notesChanged(model.deckOrder))
            }
        case .createNote:
            if let note = model.createNote() {
                handle(.noteCreated(note.id))
            }
        case .archive(let id):
            model.archive(current(id))
            _ = machine.handle(.notesChanged(model.deckOrder))
        }
    }

    // MARK: - Rendering

    private func render() {
        let state = machine.state
        let notes = model.active
        let openNote = state.openNote.flatMap { model.note($0) }
        let pending = model.pendingUndo
        layout = DeckGeometry.layout(state: state, side: preferences.side, visibleFrame: screen.visibleFrame, notes: notes.map(\.id), toast: pending != nil)
        var content = DeckContent(
            layout: layout, state: state, side: preferences.side, notes: notes, openNote: openNote,
            readOnly: model.readOnly, readOnlyNotice: model.readOnlyNotice,
            statusLine: openNote.map { model.statusLine(for: $0.id) } ?? "",
            pendingUndo: pending, folderMissing: model.store.folderIsMissing, focusToken: focusToken
        )
        content.onTab = { [weak self] in self?.handle(.tabClicked($0)) }
        content.onPlus = { [weak self] in self?.handle(.plusClicked) }
        content.onMore = { [weak self] in self?.showAllNotes() }
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
            case .archive: self.handle(.archiveRequested)
            case .togglePin:
                if let id = self.machine.state.openNote, let note = self.model.note(id) { self.model.setPinned(!note.pinned, for: id) }
            case .toggleFace:
                if let id = self.machine.state.openNote, let note = self.model.note(id) { self.model.setFace(note.face.toggled, for: id) }
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
        content.onArchive = { [weak self] in self?.handle(.archiveRequested) }
        content.onUndo = { [weak self] in
            self?.model.undoArchive()
            self?.notesChanged()
        }
        content.onAllNotes = { [weak self] in self?.showAllNotes() }
        hosting.rootView = DeckView(content: content)
        container.edgeRect = edgeRect(in: layout)
        container.deckRects = layout.tabs.map(\.frame) + [layout.plusTab] + [layout.note, layout.toast].compactMap { $0 }
        moveWindow(to: layout.panelFrame)
    }

    /// Only the content changed (typing): no new layout, no window move.
    private func refreshContent() {
        guard let id = machine.state.openNote, let note = model.note(id) else { return }
        var content = hosting.rootView.content
        content.openNote = note
        content.notes = model.active
        content.statusLine = model.statusLine(for: id)
        hosting.rootView = DeckView(content: content)
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
    private var areas: [NSTrackingArea] = []
    private var insideEdge = false
    private var insideDeck = false
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
