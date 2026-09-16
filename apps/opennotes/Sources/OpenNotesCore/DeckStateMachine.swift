import CoreGraphics
import Foundation

/// The deck's settings as the rules read them.
nonisolated public struct DeckSettings: Hashable, Sendable {
    /// How long the pointer rests on the edge before the pill fans out.
    public var hoverOpenDelay: TimeInterval
    /// How long after the pointer has left the edge and the deck a fan collapses.
    public var hoverCloseDelay: TimeInterval
    /// How long a fan the hotkey showed (read-only) stays without the pointer.
    public var hotkeyFanDelay: TimeInterval
    /// Creating is refused: the hotkey and `+` fan the deck instead.
    public var readOnly: Bool

    public init(hoverOpenDelay: TimeInterval = 0.12, hoverCloseDelay: TimeInterval = 0.35, hotkeyFanDelay: TimeInterval = 2, readOnly: Bool = false) {
        self.hoverOpenDelay = hoverOpenDelay
        self.hoverCloseDelay = hoverCloseDelay
        self.hotkeyFanDelay = hotkeyFanDelay
        self.readOnly = readOnly
    }
}

nonisolated public enum DeckTimer: Hashable, Sendable {
    case hoverOpen, hoverClose
}

/// What the deck looks like (design/products/opennotes.md, "The deck").
nonisolated public enum DeckState: Hashable, Sendable {
    case pill
    case fan
    /// One note slid out; `editing` once the keyboard focus is in it.
    case open(NoteID, editing: Bool)

    public var openNote: NoteID? {
        if case .open(let id, _) = self { return id }
        return nil
    }

    public var isEditing: Bool {
        if case .open(_, let editing) = self { return editing }
        return false
    }
}

/// What reaches the rules: the pointer over the edge strip and over the
/// deck's content, clicks, keys, the notes, the settings, the timers.
nonisolated public enum DeckEvent: Hashable, Sendable {
    case pointerEnteredEdge, pointerLeftEdge
    case pointerEnteredDeck, pointerLeftDeck
    case tabClicked(NoteID)
    case plusClicked
    /// The global hotkey: a new note, focused, from anywhere.
    case hotkey
    /// The store made the note the `.createNote` effect asked for.
    case noteCreated(NoteID)
    /// All Notes or the menu asked for this note.
    case openRequested(NoteID)
    case escape
    case clickedOutside
    /// The user put the caret in the open note.
    case editorFocused
    /// ⌘W: the next note, or back into the deck.
    case closeRequested
    /// ⌘⇧A or the footer: the open note leaves the deck.
    case archiveRequested
    /// The active notes in deck order changed (created, archived, reordered, removed).
    case notesChanged([NoteID])
    case settingsChanged(DeckSettings)
    /// The display went away, or the deck is being torn down.
    case hostLost
    case timerFired(DeckTimer)
}

/// What the controller does in response.
nonisolated public enum DeckEffect: Hashable, Sendable {
    case startTimer(DeckTimer, TimeInterval)
    case cancelTimer(DeckTimer)
    case showPill
    case showFan
    /// Slide the note out; `focus` puts the caret in it (activating the app).
    case openNote(NoteID, focus: Bool)
    /// Save and slide the note back; an empty new note is dropped.
    case closeNote(NoteID)
    /// Make a note (the store answers with `.noteCreated`).
    case createNote
    case archive(NoteID)
}

/// The deck's rules, pure: the controller owns the windows and timers and
/// feeds events back. Hover fans the pill out after a delay and collapses
/// it after the pointer has left both the edge and the deck; only a click,
/// the hotkey, ⌘W or All Notes opens a note; an open note closes only on
/// Escape, a click outside, the hotkey, ⌘W or Archive, and closing always
/// saves.
nonisolated public struct DeckStateMachine: Hashable, Sendable {
    public private(set) var settings: DeckSettings
    public private(set) var state: DeckState = .pill
    public private(set) var pointerOnEdge = false
    public private(set) var pointerInDeck = false
    public private(set) var pendingOpen = false
    public private(set) var pendingClose = false
    /// The active notes in deck order, for ⌘W.
    public private(set) var order: [NoteID] = []

    public init(settings: DeckSettings = DeckSettings(), notes: [NoteID] = []) {
        self.settings = settings
        order = notes
    }

    public var isOpen: Bool { state.openNote != nil }

    public mutating func handle(_ event: DeckEvent) -> [DeckEffect] {
        var effects: [DeckEffect] = []
        switch event {
        case .pointerEnteredEdge:
            pointerOnEdge = true
            cancelClose(&effects)
            if state == .pill, !pendingOpen {
                pendingOpen = true
                effects.append(.startTimer(.hoverOpen, settings.hoverOpenDelay))
            }
        case .pointerLeftEdge:
            pointerOnEdge = false
            cancelPendingOpen(&effects)
            scheduleCloseIfFanned(&effects)
        case .pointerEnteredDeck:
            pointerInDeck = true
            cancelClose(&effects)
        case .pointerLeftDeck:
            pointerInDeck = false
            scheduleCloseIfFanned(&effects)
        case .timerFired(.hoverOpen):
            pendingOpen = false
            if state == .pill, pointerOnEdge {
                state = .fan
                effects.append(.showFan)
            }
        case .timerFired(.hoverClose):
            pendingClose = false
            if state == .fan, !pointerOnEdge, !pointerInDeck {
                state = .pill
                effects.append(.showPill)
            }
        case .tabClicked(let id):
            guard order.contains(id) else { break }
            if case .open(let current, _) = state {
                guard current != id else { break }
                effects.append(.closeNote(current))
            }
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            state = .open(id, editing: false)
            effects.append(.openNote(id, focus: false))
        case .openRequested(let id):
            guard order.contains(id) else { break }
            if case .open(let current, _) = state, current != id {
                effects.append(.closeNote(current))
            }
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            state = .open(id, editing: true)
            effects.append(.openNote(id, focus: true))
        case .plusClicked, .hotkey:
            if case .open(let current, _) = state {
                effects.append(.closeNote(current))
            }
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            if settings.readOnly {
                state = .fan
                effects.append(.showFan)
                if !pointerOnEdge, !pointerInDeck {
                    pendingClose = true
                    effects.append(.startTimer(.hoverClose, settings.hotkeyFanDelay))
                }
            } else {
                state = .fan
                effects.append(.createNote)
            }
        case .noteCreated(let id):
            if !order.contains(id) { order.insert(id, at: 0) }
            if case .open(let current, _) = state, current != id {
                effects.append(.closeNote(current))
            }
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            state = .open(id, editing: true)
            effects.append(.openNote(id, focus: true))
        case .editorFocused:
            if case .open(let id, false) = state { state = .open(id, editing: true) }
        case .escape:
            switch state {
            case .open(let id, _):
                effects.append(.closeNote(id))
                rest(&effects)
            case .fan:
                cancelClose(&effects)
                state = .pill
                effects.append(.showPill)
            case .pill:
                cancelPendingOpen(&effects)
            }
        case .clickedOutside:
            switch state {
            case .open(let id, _):
                effects.append(.closeNote(id))
                cancelClose(&effects)
                state = .pill
                effects.append(.showPill)
            case .fan:
                cancelClose(&effects)
                state = .pill
                effects.append(.showPill)
            case .pill:
                break
            }
        case .closeRequested:
            guard case .open(let id, _) = state else { break }
            effects.append(.closeNote(id))
            if let index = order.firstIndex(of: id), index + 1 < order.count {
                let next = order[index + 1]
                state = .open(next, editing: true)
                effects.append(.openNote(next, focus: true))
            } else {
                rest(&effects)
            }
        case .archiveRequested:
            guard case .open(let id, _) = state else { break }
            effects.append(.closeNote(id))
            effects.append(.archive(id))
            order.removeAll { $0 == id }
            rest(&effects)
        case .notesChanged(let ids):
            order = ids
            if case .open(let id, _) = state, !ids.contains(id) {
                effects.append(.closeNote(id))
                rest(&effects)
            }
        case .settingsChanged(let next):
            settings = next
        case .hostLost:
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            pointerOnEdge = false
            pointerInDeck = false
            if case .open(let id, _) = state {
                effects.append(.closeNote(id))
            }
            state = .pill
            effects.append(.showPill)
        }
        return effects
    }

    /// After a note closes: the fan while the pointer is still here, else the pill.
    private mutating func rest(_ effects: inout [DeckEffect]) {
        if pointerOnEdge || pointerInDeck {
            state = .fan
            effects.append(.showFan)
        } else {
            cancelClose(&effects)
            state = .pill
            effects.append(.showPill)
        }
    }

    private mutating func cancelPendingOpen(_ effects: inout [DeckEffect]) {
        guard pendingOpen else { return }
        pendingOpen = false
        effects.append(.cancelTimer(.hoverOpen))
    }

    private mutating func cancelClose(_ effects: inout [DeckEffect]) {
        guard pendingClose else { return }
        pendingClose = false
        effects.append(.cancelTimer(.hoverClose))
    }

    private mutating func scheduleCloseIfFanned(_ effects: inout [DeckEffect]) {
        guard state == .fan, !pointerOnEdge, !pointerInDeck, !pendingClose else { return }
        pendingClose = true
        effects.append(.startTimer(.hoverClose, settings.hoverCloseDelay))
    }
}

/// Which edge the deck docks to.
nonisolated public enum DeckSide: String, CaseIterable, Sendable, Codable {
    case right, left

    public var title: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        }
    }
}

/// Which displays host a deck.
nonisolated public enum DeckDisplay: String, CaseIterable, Sendable, Codable {
    case main, pointer, every

    public var title: String {
        switch self {
        case .main: "The main display"
        case .pointer: "The display with the pointer"
        case .every: "Every display"
        }
    }
}

/// The deck's sizes (apps/opennotes/design/tokens.json, `deck/*`).
nonisolated public struct DeckMetrics: Hashable, Sendable {
    public var pillWidth: CGFloat = 14
    public var pillMinHeight: CGFloat = 96
    public var dashLength: CGFloat = 18
    public var dashSpacing: CGFloat = 10
    public var tabWidth: CGFloat = 40
    public var tabHeight: CGFloat = 112
    public var tabOverlap: CGFloat = 24
    public var plusTabHeight: CGFloat = 40
    public var noteWidth: CGFloat = 320
    public var noteHeight: CGFloat = 360
    public var gap: CGFloat = 8
    /// Room for the open note's shadow, and the pointer past the edge.
    public var margin: CGFloat = 24
    public var maxTabs = 8

    public init() {}
}

/// Where everything goes, in the panel's own coordinates (origin bottom
/// left, as AppKit has it) and the panel's frame on the screen. Pure, so
/// the layout is tested without a window.
nonisolated public struct DeckLayout: Hashable, Sendable {
    public struct Tab: Hashable, Sendable {
        public var id: NoteID?
        /// The "+N more" tab has no id and this many hidden notes.
        public var more: Int
        public var frame: CGRect
    }

    public var panelFrame: CGRect
    public var pill: CGRect
    public var tabs: [Tab]
    public var plusTab: CGRect
    public var note: CGRect?
}

nonisolated public enum DeckGeometry {
    /// The layout for a state. `visibleFrame` is the screen's, in AppKit
    /// coordinates; the deck is centred on it vertically and clamped inside.
    public static func layout(state: DeckState, side: DeckSide, visibleFrame: CGRect, notes: [NoteID], metrics: DeckMetrics = DeckMetrics()) -> DeckLayout {
        let shown = Array(notes.prefix(metrics.maxTabs))
        let hidden = max(0, notes.count - shown.count)
        var tabCount = shown.count + (hidden > 0 ? 1 : 0)
        let step = metrics.tabHeight - metrics.tabOverlap
        let fanHeight = tabCount == 0 ? 0 : metrics.tabHeight + CGFloat(tabCount - 1) * step
        let stackHeight = fanHeight + (tabCount == 0 ? 0 : metrics.gap) + metrics.plusTabHeight
        let pillHeight = max(metrics.pillMinHeight, CGFloat(min(notes.count, metrics.maxTabs + 1)) * metrics.dashSpacing + 2 * metrics.dashSpacing)
        let contentHeight: CGFloat
        let contentWidth: CGFloat
        switch state {
        case .pill:
            contentHeight = pillHeight
            contentWidth = metrics.pillWidth
        case .fan:
            contentHeight = stackHeight
            contentWidth = metrics.tabWidth
        case .open:
            contentHeight = max(stackHeight, metrics.noteHeight)
            contentWidth = metrics.tabWidth + metrics.gap + metrics.noteWidth
        }
        let panelHeight = min(contentHeight + 2 * metrics.margin, visibleFrame.height)
        let panelWidth = contentWidth + metrics.margin
        let originY = (visibleFrame.midY - panelHeight / 2).rounded()
        let clampedY = min(max(originY, visibleFrame.minY), visibleFrame.maxY - panelHeight)
        let originX = side == .right ? visibleFrame.maxX - panelWidth : visibleFrame.minX
        let panelFrame = CGRect(x: originX, y: clampedY, width: panelWidth, height: panelHeight)

        // Local coordinates: the content hugs the docked edge.
        func edgeX(width: CGFloat) -> CGFloat {
            side == .right ? panelWidth - width : 0
        }
        let top = panelHeight - metrics.margin
        let pill = CGRect(x: edgeX(width: metrics.pillWidth), y: top - pillHeight, width: metrics.pillWidth, height: pillHeight)
        var tabs: [DeckLayout.Tab] = []
        var y = top
        for id in shown {
            y -= (tabs.isEmpty ? metrics.tabHeight : step)
            tabs.append(.init(id: id, more: 0, frame: CGRect(x: edgeX(width: metrics.tabWidth), y: y, width: metrics.tabWidth, height: metrics.tabHeight)))
        }
        if hidden > 0 {
            y -= (tabs.isEmpty ? metrics.tabHeight : step)
            tabs.append(.init(id: nil, more: hidden, frame: CGRect(x: edgeX(width: metrics.tabWidth), y: y, width: metrics.tabWidth, height: metrics.tabHeight)))
        }
        tabCount = tabs.count
        let plusY = (tabCount == 0 ? top : y) - (tabCount == 0 ? 0 : metrics.gap) - metrics.plusTabHeight
        let plusTab = CGRect(x: edgeX(width: metrics.tabWidth), y: plusY, width: metrics.tabWidth, height: metrics.plusTabHeight)
        var note: CGRect?
        if case .open = state {
            let noteX = side == .right ? edgeX(width: metrics.tabWidth) - metrics.gap - metrics.noteWidth : metrics.tabWidth + metrics.gap
            note = CGRect(x: noteX, y: top - metrics.noteHeight, width: metrics.noteWidth, height: metrics.noteHeight)
        }
        return DeckLayout(panelFrame: panelFrame, pill: pill, tabs: tabs, plusTab: plusTab, note: note)
    }
}
