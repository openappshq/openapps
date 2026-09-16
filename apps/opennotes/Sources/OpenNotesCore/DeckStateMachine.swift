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
    /// Text, a link or files let go over the pill or the fan: a new note
    /// with what was dropped, focused — the hotkey's path, the controller
    /// supplying the text when the store answers `.createNote`. Refused
    /// while read-only the same way (the fan shows, nothing is made).
    case dropped
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
    /// The active notes in deck order changed (created, archived, reordered,
    /// removed), and which of them are pinned (the group a drag stays in).
    case notesChanged([NoteID], pinned: Set<NoteID> = [])
    /// A note's identity moved (its file took its title's name; the user's
    /// text went to a conflict copy): the open note, the order and a drag
    /// in flight follow.
    case noteRenamed(from: NoteID, to: NoteID)
    /// A tab was lifted (the pointer moved past `DeckMetrics.dragThreshold`
    /// with the button down): the fan stays out while it is held.
    case tabLifted(NoteID)
    /// The lifted tab was let go over this slot of the deck (nil: nowhere
    /// new, or the drag was given up); the fan may collapse again.
    case tabDropped(at: Int?)
    /// Put this note at this index of the deck order — a drop, or ⌥⌘↑ /
    /// ⌥⌘↓ on the open note. The index is clamped into the note's group
    /// (pinned notes first, `DeckReorder`); refused while read-only.
    case moveRequested(NoteID, to: Int)
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
    /// The note is already open: only the caret goes into it.
    case focusNote(NoteID)
    /// Save and slide the note back; an empty new note is dropped.
    case closeNote(NoteID)
    /// Make a note (the store answers with `.noteCreated`).
    case createNote
    case archive(NoteID)
    /// The active notes in this order: the one write the All Notes list
    /// makes too (`order` in the files of the notes that moved). The store
    /// answers through `.notesChanged`; the machine's order waits for it.
    case reorder([NoteID])
    /// The lifted tab goes back where it was (Escape, or the note left the
    /// deck under the pointer).
    case cancelDrag
}

/// The deck's rules, pure: the controller owns the windows and timers and
/// feeds events back. Hover fans the pill out after a delay and collapses
/// it after the pointer has left both the edge and the deck; only a click,
/// the hotkey, a drop, ⌘W or All Notes opens a note; an open note closes only on
/// Escape, a click outside, the hotkey, ⌘W or Archive, and closing always
/// saves. A lifted tab holds the fan out until it is dropped; the drop and
/// ⌥⌘↑ / ⌥⌘↓ ask for one `.reorder`, the write the All Notes list makes.
nonisolated public struct DeckStateMachine: Hashable, Sendable {
    public private(set) var settings: DeckSettings
    public private(set) var state: DeckState = .pill
    public private(set) var pointerOnEdge = false
    public private(set) var pointerInDeck = false
    public private(set) var pendingOpen = false
    public private(set) var pendingClose = false
    /// The active notes in deck order, for ⌘W and the moves.
    public private(set) var order: [NoteID] = []
    /// The pinned ones among them: a move never crosses the group boundary.
    public private(set) var pinned: Set<NoteID> = []
    /// The tab being dragged, while one is.
    public private(set) var dragging: NoteID?

    public init(settings: DeckSettings = DeckSettings(), notes: [NoteID] = [], pinned: Set<NoteID> = []) {
        self.settings = settings
        order = notes
        self.pinned = pinned
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
            if state == .fan, !pointerOnEdge, !pointerInDeck, dragging == nil {
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
            if case .open(let current, _) = state {
                if current == id {
                    // Already out: the caret only, so the deck's hold on the
                    // note is taken once per open and released once per close.
                    state = .open(id, editing: true)
                    effects.append(.focusNote(id))
                    break
                }
                effects.append(.closeNote(current))
            }
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            state = .open(id, editing: true)
            effects.append(.openNote(id, focus: true))
        case .plusClicked, .hotkey, .dropped:
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
            // A lifted tab goes back first; the deck itself stays as it is.
            if dragging != nil {
                dragging = nil
                effects.append(.cancelDrag)
                scheduleCloseIfFanned(&effects)
                break
            }
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
        case .notesChanged(let ids, let pinnedIDs):
            order = ids
            pinned = pinnedIDs
            if let dragging, !ids.contains(dragging) {
                // The note under the pointer left the deck (archived from
                // All Notes, its file removed): nothing to drop.
                self.dragging = nil
                effects.append(.cancelDrag)
                scheduleCloseIfFanned(&effects)
            }
            if case .open(let id, _) = state, !ids.contains(id) {
                effects.append(.closeNote(id))
                rest(&effects)
            }
        case .noteRenamed(let from, let to):
            if let index = order.firstIndex(of: from) {
                if order.contains(to) { order.remove(at: index) } else { order[index] = to }
            }
            if pinned.remove(from) != nil { pinned.insert(to) }
            if dragging == from { dragging = to }
            if case .open(let current, let editing) = state, current == from {
                state = .open(to, editing: editing)
            }
        case .tabLifted(let id):
            guard order.contains(id), !settings.readOnly else { break }
            dragging = id
            cancelPendingOpen(&effects)
            cancelClose(&effects)
        case .tabDropped(let index):
            guard let id = dragging else { break }
            dragging = nil
            if let index { move(id, to: index, &effects) }
            scheduleCloseIfFanned(&effects)
        case .moveRequested(let id, let index):
            move(id, to: index, &effects)
        case .settingsChanged(let next):
            settings = next
        case .hostLost:
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            pointerOnEdge = false
            pointerInDeck = false
            if dragging != nil {
                dragging = nil
                effects.append(.cancelDrag)
            }
            if case .open(let id, _) = state {
                effects.append(.closeNote(id))
            }
            state = .pill
            effects.append(.showPill)
        }
        return effects
    }

    /// One `.reorder` when the note lands somewhere new inside its group;
    /// nothing while read-only, for a note not in the deck, or a slot that
    /// clamps back to where it is. The order itself follows the store's
    /// `.notesChanged`, so a refused write leaves nothing stale here.
    private func move(_ id: NoteID, to index: Int, _ effects: inout [DeckEffect]) {
        guard !settings.readOnly, let reordered = DeckReorder.moved(id, to: index, in: order, pinned: pinned) else { return }
        effects.append(.reorder(reordered))
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
        guard state == .fan, !pointerOnEdge, !pointerInDeck, !pendingClose, dragging == nil else { return }
        pendingClose = true
        effects.append(.startTimer(.hoverClose, settings.hoverCloseDelay))
    }
}

/// Where a note may land in the deck: pinned notes come first
/// (`Note.deckOrder`), so a move stays inside its own group — a drop past
/// the boundary snaps back to the group's edge, and a note is never pinned
/// or unpinned by a drag (design/products/opennotes.md, "The deck"). Pure,
/// shared by the rules and by the view that shows the gap while dragging.
nonisolated public enum DeckReorder {
    /// The nearest slot to `index` the note may take; nil when the note is
    /// not in the order.
    public static func clampedIndex(_ index: Int, for id: NoteID, in order: [NoteID], pinned: Set<NoteID>) -> Int? {
        guard order.contains(id) else { return nil }
        let isPinned = pinned.contains(id)
        let group = order.indices.filter { pinned.contains(order[$0]) == isPinned }
        guard let first = group.first, let last = group.last else { return nil }
        return min(max(index, first), last)
    }

    /// The order with the note at the clamped slot; nil when that is where
    /// it already is (or the note is not in the order).
    public static func moved(_ id: NoteID, to index: Int, in order: [NoteID], pinned: Set<NoteID>) -> [NoteID]? {
        guard let target = clampedIndex(index, for: id, in: order, pinned: pinned), let current = order.firstIndex(of: id), target != current else { return nil }
        var result = order
        result.remove(at: current)
        result.insert(id, at: target)
        return result
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
    /// Dashes the pill shows before a dot stands for the rest.
    public var pillMaxDashes = 8
    public var tabWidth: CGFloat = 40
    public var tabHeight: CGFloat = 112
    /// Between two tabs: air enough for each to read as its own card.
    public var tabGap: CGFloat = 6
    public var plusTabHeight: CGFloat = 40
    public var noteWidth: CGFloat = 320
    public var noteHeight: CGFloat = 360
    public var toastWidth: CGFloat = 260
    public var toastHeight: CGFloat = 36
    /// A refused drop's notice under the deck: the toast's width, room
    /// for the license line's three lines.
    public var noticeHeight: CGFloat = 58
    public var gap: CGFloat = 8
    /// Room for the open note's shadow, and the pointer past the edge.
    public var margin: CGFloat = 24
    /// How far the pointer travels along the deck, button down, before a
    /// tab lifts; anything shorter is a click that opens the note.
    public var dragThreshold: CGFloat = 6
    /// The fade over the fan's ends while more tabs lie beyond them.
    public var fadeLength: CGFloat = 28
    /// A fanned tab's tilt, degrees, at least and at most (`DeckTilt`).
    public var tiltMin: CGFloat = 1.5
    public var tiltMax: CGFloat = 3
    /// How far a tilted tab may sit in from the edge, at most.
    public var tiltInset: CGFloat = 3

    public init() {}

    /// From one tab's top to the next's.
    public var tabStep: CGFloat { tabHeight + tabGap }
}

/// Where everything goes, in the panel's own coordinates (origin bottom
/// left, as AppKit has it) and the panel's frame on the screen. Pure, so
/// the layout is tested without a window.
nonisolated public struct DeckLayout: Hashable, Sendable {
    public struct Tab: Hashable, Sendable {
        public var id: NoteID
        /// Where the tab is now, the scroll applied: a tab past the fan's
        /// ends is still listed, and the fan's mask hides it.
        public var frame: CGRect
    }

    public var panelFrame: CGRect
    public var pill: CGRect
    /// Every active note's tab, in deck order.
    public var tabs: [Tab]
    /// The fan's window onto the tabs: what shows, and where the fades go.
    /// The whole panel width, so a lifted tab's shadow is not cut.
    public var fan: CGRect
    /// How far the tabs are scrolled up past the fan's top, clamped.
    public var scroll: CGFloat
    /// The furthest the tabs can scroll: what does not fit the fan.
    public var maxScroll: CGFloat
    public var plusTab: CGRect
    public var note: CGRect?
    /// The archive toast ("Archived … · Undo") under the deck while one
    /// shows, or the taller notice a refused drop shows in its place.
    public var toast: CGRect?
    /// From one tab's top to the next's.
    public var tabStep: CGFloat

    /// More tabs lie above the fan's top: the top fade shows.
    public var canScrollUp: Bool { scroll > 0 }
    /// More tabs lie below the fan's bottom: the bottom fade shows.
    public var canScrollDown: Bool { scroll < maxScroll }
}

nonisolated public enum DeckGeometry {
    /// The layout for a state. `visibleFrame` is the screen's, in AppKit
    /// coordinates; the deck is centred on it vertically and clamped inside.
    /// Every active note gets a tab, `tabStep` apart; what does not fit
    /// between the margins and the `+` tab scrolls (`scroll`, clamped to
    /// `maxScroll`), the `+` tab staying put under the fan. `toast` leaves
    /// room under the deck for the archive toast, `notice` for the taller
    /// line a refused drop shows there instead (the same rect, `toast`).
    public static func layout(state: DeckState, side: DeckSide, visibleFrame: CGRect, notes: [NoteID], toast: Bool = false, notice: Bool = false, scroll requested: CGFloat = 0, metrics: DeckMetrics = DeckMetrics()) -> DeckLayout {
        let step = metrics.tabStep
        let count = notes.count
        let stackHeight = count == 0 ? 0 : metrics.tabHeight + CGFloat(count - 1) * step
        // The fan takes what the screen leaves after the margins and the
        // plus tab; the rest scrolls.
        let available = max(0, visibleFrame.height - 2 * metrics.margin - metrics.plusTabHeight - metrics.gap)
        let fanHeight = min(stackHeight, available)
        let maxScroll = max(0, stackHeight - fanHeight)
        let scroll = min(max(requested, 0), maxScroll)
        let fanBlock = fanHeight + (count == 0 ? 0 : metrics.gap) + metrics.plusTabHeight
        let pillHeight = max(metrics.pillMinHeight, CGFloat(min(count, metrics.pillMaxDashes + 1)) * metrics.dashSpacing + 2 * metrics.dashSpacing)
        var contentHeight: CGFloat
        var contentWidth: CGFloat
        switch state {
        case .pill:
            contentHeight = pillHeight
            contentWidth = metrics.pillWidth
        case .fan:
            contentHeight = fanBlock
            contentWidth = metrics.tabWidth
        case .open:
            contentHeight = max(fanBlock, metrics.noteHeight)
            contentWidth = metrics.tabWidth + metrics.gap + metrics.noteWidth
        }
        let messageHeight: CGFloat? = notice ? metrics.noticeHeight : toast ? metrics.toastHeight : nil
        if let messageHeight {
            contentWidth = max(contentWidth, metrics.toastWidth)
            contentHeight += metrics.gap + messageHeight
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
        let fan = CGRect(x: 0, y: top - fanHeight, width: panelWidth, height: fanHeight)
        var tabs: [DeckLayout.Tab] = []
        for (index, id) in notes.enumerated() {
            // Down from the fan's top by the tab's place in the stack, up
            // again by the scroll.
            let tabTop = top - CGFloat(index) * step + scroll
            tabs.append(.init(id: id, frame: CGRect(x: edgeX(width: metrics.tabWidth), y: tabTop - metrics.tabHeight, width: metrics.tabWidth, height: metrics.tabHeight)))
        }
        let plusY = fan.minY - (count == 0 ? 0 : metrics.gap) - metrics.plusTabHeight
        let plusTab = CGRect(x: edgeX(width: metrics.tabWidth), y: plusY, width: metrics.tabWidth, height: metrics.plusTabHeight)
        var note: CGRect?
        if case .open = state {
            let noteX = side == .right ? edgeX(width: metrics.tabWidth) - metrics.gap - metrics.noteWidth : metrics.tabWidth + metrics.gap
            note = CGRect(x: noteX, y: top - metrics.noteHeight, width: metrics.noteWidth, height: metrics.noteHeight)
        }
        var toastRect: CGRect?
        if let messageHeight {
            toastRect = CGRect(x: edgeX(width: metrics.toastWidth), y: metrics.margin, width: metrics.toastWidth, height: messageHeight)
        }
        return DeckLayout(panelFrame: panelFrame, pill: pill, tabs: tabs, fan: fan, scroll: scroll, maxScroll: maxScroll, plusTab: plusTab, note: note, toast: toastRect, tabStep: step)
    }

    /// The scroll that keeps this note's tab wholly inside the fan, moving
    /// as little as possible from `layout.scroll`: the open or last-used
    /// tab is kept in view. Nil for a note with no tab.
    public static func scroll(revealing id: NoteID, in layout: DeckLayout, metrics: DeckMetrics = DeckMetrics()) -> CGFloat? {
        guard let index = layout.tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tabTop = CGFloat(index) * layout.tabStep
        let tabBottom = tabTop + metrics.tabHeight
        var scroll = layout.scroll
        if tabTop < scroll {
            scroll = tabTop
        } else if tabBottom > scroll + layout.fan.height {
            scroll = tabBottom - layout.fan.height
        }
        return min(max(scroll, 0), layout.maxScroll)
    }
}

/// A fanned tab's small, stable tilt (design/products/opennotes.md, "The
/// deck"): seeded from the note's id, never from a launch or a render,
/// so a tab leans the same way every time and its neighbours read as
/// separate papers stuck on at their own angles. The open note's tab and
/// a lifted tab are straight.
nonisolated public enum DeckTilt {
    /// Degrees, in `tiltMin...tiltMax` either way, and the inset from
    /// the edge in points, `0...tiltInset`.
    public static func tilt(for id: NoteID, metrics: DeckMetrics = DeckMetrics()) -> (degrees: CGFloat, inset: CGFloat) {
        // FNV-1a over the id's bytes: a hash that is the same in every
        // process (Swift's own is seeded per launch).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let magnitude = CGFloat(hash % 1000) / 999
        let degrees = metrics.tiltMin + (metrics.tiltMax - metrics.tiltMin) * magnitude
        let sign: CGFloat = (hash >> 16) & 1 == 0 ? 1 : -1
        let inset = CGFloat((hash >> 24) % 1000) / 999 * metrics.tiltInset
        return (degrees * sign, inset)
    }
}
