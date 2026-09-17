import OpenNotesCore
import SwiftUI

/// What the deck's SwiftUI content needs from its controller: the layout
/// for the state, the notes, and what each control does.
struct DeckContent {
    var layout: DeckLayout
    var state: DeckState
    var side: DeckSide
    var notes: [Note]
    var openNote: Note?
    var readOnly: Bool
    var readOnlyNotice: String
    var statusLine: String
    var pendingUndo: ArchiveUndo.Pending?
    var folderMissing: Bool
    /// A new value puts the caret in the open note; nil leaves it.
    var focusToken: Int?
    /// The license pill at the top of the open note reads it on every
    /// body; the footer's read-only line opens Settings → License through it.
    var license = LicenseStatus()
    /// A new value puts a lifted tab back where it was (Escape, the note
    /// leaving the deck); nil leaves the drag alone.
    var dragCancelToken = 0
    /// The preview harness: a tab shown lifted, mid-drag, with no pointer.
    var staticDrag: DeckDrag?
    /// The preview harness: a tab shown hovered, with no pointer.
    var staticHover: NoteID?
    /// Text, a link or files are held over the deck and would make a note:
    /// the tabs' edges lift (at rest), or the `+` tab lights up, as the target.
    var dropTarget = false
    /// A drop is refused while read-only: the notice, shown under the deck
    /// in the toast's place while the drag hovers.
    var dropRefusal: String?
    /// Each note's checklist for its tab, from the model's cache
    /// (`AppModel.checklistProgress`): nothing for a note without boxes,
    /// nothing for one whose whole body is not in memory.
    var progress: [NoteID: MarkdownLite.ChecklistProgress] = [:]
    /// Asked by the editor at every keystroke, paste and checkbox click:
    /// the license now, not `readOnly` as rendered.
    var mayEdit: () -> Bool = { true }
    var onTab: (NoteID) -> Void = { _ in }
    /// The pointer moved past the drag threshold on a tab: true when the
    /// controller accepted the lift (the license, asked now), and only
    /// then does the tab rise; false leaves it a press.
    var onTabLifted: (NoteID) -> Bool = { _ in true }
    /// The lifted tab was let go over this slot (nil: nowhere new).
    var onTabDropped: (Int?) -> Void = { _ in }
    /// VoiceOver's Move up / Move down on a tab: one slot along the deck.
    var onMove: (NoteID, _ step: Int) -> Void = { _, _ in }
    /// The fan scrolled by this much (points; positive moves the tabs up,
    /// showing what lies below): a drag on the deck off the tabs, or a
    /// lifted tab held at the fan's end.
    var onScroll: (CGFloat) -> Void = { _ in }
    var onPlus: () -> Void = {}
    var onTextChange: (String) -> Void = { _ in }
    var onCommand: (EditorCommand) -> Void = { _ in }
    var onFocus: () -> Void = {}
    /// What notes without their own font read (Settings → Notes); every
    /// note's look is `NoteAppearance.resolve(note, defaults:)`.
    var defaults = NoteAppearance.Defaults()
    var onColor: (NoteColor) -> Void = { _ in }
    /// Custom…: the system colour panel for the open note.
    var onCustomColor: () -> Void = {}
    /// ⌘⇧M: the next face.
    var onFace: () -> Void = {}
    /// The font menu's pick: a face, a family, or nil for the default.
    var onTypeface: (NoteTypeface?) -> Void = { _ in }
    /// The font menu's size: nil for the default.
    var onFontSize: (Int?) -> Void = { _ in }
    var onPin: () -> Void = {}
    var onArchive: () -> Void = {}
    var onUndo: () -> Void = {}
    var onAllNotes: () -> Void = {}
}

/// A tab being dragged along the deck: which, and where its centre is
/// now (the panel's SwiftUI coordinates, y down the screen), so a fan
/// that scrolls under the pointer changes nothing about where the tab is.
struct DeckDrag: Hashable {
    var id: NoteID
    var centerY: CGFloat
}

/// The deck: the fan of tabs, the `+` tab, the open note and the archive
/// toast, each placed by `DeckLayout` (AppKit coordinates, flipped here).
/// At rest the same tabs, folded in: each one's edge peeking out of the
/// screen edge, `restWidth` wide, in its place in the fan and at a share
/// of its tilt, so fanning out is only the tabs widening. Every element
/// animates between layouts. The tabs are separate papers, each at its
/// own small tilt (`DeckTilt`), stacked in a fan that scrolls when they
/// do not fit, fading at whichever end has more beyond it. A tab pressed
/// and moved past the threshold lifts (straight, larger, a deeper shadow)
/// and follows the pointer along the deck while the others slide out of
/// its way (`DeckReorder` says where it may land); held at either end it
/// scrolls the fan under itself (`DeckEdgeHold`); the drop asks the
/// controller for the move.
struct DeckView: View {
    let content: DeckContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewRendering) private var previewRendering
    @State private var drag: DeckDrag?
    /// Where inside the lifted tab the pointer took it (from its centre).
    @State private var grab: CGFloat = 0
    /// The tab whose press was cancelled from outside (Escape, the note
    /// gone): its mouse-up is neither a click nor a drop.
    @State private var cancelled: NoteID?
    @State private var hovered: NoteID?
    /// The last pointer position of a scroll drag on the deck's bare axis.
    @State private var scrollDragY: CGFloat?
    /// The tab whose checklist just completed: its count ticks once.
    @State private var ticked: NoteID?
    /// The lifted tab held at an end of the fan: the timer that scrolls
    /// the fan under it.
    @State private var edgeHold = EdgeHoldTimer()

    private var height: CGFloat { content.layout.panelFrame.height }
    private var atRest: Bool { content.state == .rest }
    private static let lift = Animation.spring(response: 0.3, dampingFraction: 0.72)
    private static let tick = Animation.spring(response: 0.28, dampingFraction: 0.45)
    private static let space = "deck"
    private var metrics: DeckMetrics { DeckMetrics() }

    /// Which notes have every box ticked: a note going from not to done
    /// is the moment the tab ticks. A tab at rest shows no count, so
    /// nothing is counted there (and nothing ticks when the fan next
    /// opens on a list that was already done).
    private var completion: [NoteID: Bool] {
        atRest ? [:] : content.progress.mapValues(\.isComplete)
    }

    var body: some View {
        let placed = placedTabs
        let progress = content.progress
        ZStack(alignment: .topLeading) {
            Color.clear
            fanBackground
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(placed, id: \.id) { placement in
                    tabView(placement, progress: progress[placement.id])
                }
            }
            .frame(width: content.layout.panelFrame.width, height: height, alignment: .topLeading)
            .mask(alignment: .topLeading) { fanMask }
            plusTab
            if let noteRect = content.layout.note, let note = content.openNote {
                NoteCard(note: note, content: content)
                    .frame(width: noteRect.width, height: noteRect.height)
                    .position(center(noteRect))
                    .transition(.move(edge: content.side == .right ? .trailing : .leading).combined(with: .opacity))
            }
            if let toastRect = content.layout.toast, let refusal = content.dropRefusal {
                dropNotice(refusal)
                    .frame(width: toastRect.width, height: toastRect.height)
                    .position(center(toastRect))
                    .transition(.opacity)
            } else if let toastRect = content.layout.toast, let pending = content.pendingUndo {
                toast(pending)
                    .frame(width: toastRect.width, height: toastRect.height)
                    .position(center(toastRect))
                    .transition(.opacity)
            }
        }
        .frame(width: content.layout.panelFrame.width, height: height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .animation(reduceMotion ? nil : .easeOut(duration: Brand.Motion.standard), value: content.state)
        // The others slide into the gap, the lifted one settles: a spring;
        // a reorder that lands from elsewhere (All Notes, the keyboard)
        // takes the same movement. Reduce Motion makes them instant.
        .animation(reduceMotion ? nil : Self.lift, value: placed.map(\.slot))
        .animation(reduceMotion ? nil : Self.lift, value: activeDrag?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: Brand.Motion.fast), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: Brand.Motion.fast), value: content.dropTarget)
        .animation(reduceMotion ? nil : Self.tick, value: ticked)
        // The last box of a list ticked: its tab ticks once (a note that
        // was already done, or arrives done, does nothing). Reduce Motion
        // shows the new count with no movement.
        .onChange(of: completion) { before, after in
            guard !reduceMotion, ticked == nil, let id = after.first(where: { $0.value && before[$0.key] == false })?.key else { return }
            ticked = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { ticked = nil }
        }
        .onChange(of: content.dragCancelToken) {
            guard let current = drag else { return }
            cancelled = current.id
            drag = nil
            edgeHold.end()
        }
        .onChange(of: content.notes.map(\.id)) {
            guard let current = drag, !content.notes.contains(where: { $0.id == current.id }) else { return }
            cancelled = current.id
            drag = nil
            edgeHold.end()
        }
        // The fan reached an end under the held tab (or can scroll again
        // after the layout changed): the hold is judged afresh.
        .onChange(of: [content.layout.canScrollUp, content.layout.canScrollDown]) {
            if let current = drag { updateEdgeHold(for: current) }
        }
        .onDisappear { edgeHold.end() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenNotes deck")
    }

    private func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: height - rect.midY)
    }

    /// The tab's paper as drawn: `bleed` wider than its frame, the extra
    /// lying past the screen edge, so a tilted, inset or lifted tab never
    /// shows the wallpaper between itself and the edge. Its centre, in
    /// SwiftUI coordinates.
    private func paperCenter(_ frame: CGRect) -> CGPoint {
        let bleed = metrics.edgeBleed
        let x = content.side == .right ? frame.midX + bleed / 2 : frame.midX - bleed / 2
        return CGPoint(x: x, y: height - frame.midY)
    }

    // MARK: - The fan

    /// The fan's window, in SwiftUI coordinates.
    private var fanRect: CGRect {
        let fan = content.layout.fan
        return CGRect(x: fan.minX, y: height - fan.maxY, width: fan.width, height: fan.height)
    }

    /// Opaque over the fan, fading out over `fadeLength` at an end that has
    /// more tabs beyond it; nothing outside the fan, so a scrolled-away
    /// tab is not drawn.
    private var fanMask: some View {
        let rect = fanRect
        let fade = min(metrics.fadeLength, rect.height / 3)
        let up = content.layout.canScrollUp
        let down = content.layout.canScrollDown
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: up ? .clear : .black, location: 0))
        if up, rect.height > 0 { stops.append(.init(color: .black, location: fade / rect.height)) }
        if down, rect.height > 0 { stops.append(.init(color: .black, location: 1 - fade / rect.height)) }
        stops.append(.init(color: down ? .clear : .black, location: 1))
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    /// The bare deck axis under the tabs: a drag along it scrolls the fan.
    private var fanBackground: some View {
        let rect = fanRect
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if let last = scrollDragY { content.onScroll(last - value.location.y) }
                        scrollDragY = value.location.y
                    }
                    .onEnded { _ in scrollDragY = nil }
            )
    }

    // MARK: - Where the tabs are

    /// One tab as drawn: its layout slot, the frame it shows at now, and
    /// whether it is the lifted one.
    private struct Placement: Hashable {
        var id: NoteID
        var tab: DeckLayout.Tab
        /// The index of the slot the tab occupies (the projected order).
        var slot: Int
        var frame: CGRect
        var lifted: Bool
    }

    private var activeDrag: DeckDrag? { content.staticDrag ?? drag }

    private var order: [NoteID] { content.layout.tabs.map(\.id) }
    private var pinnedIDs: Set<NoteID> { Set(content.notes.filter(\.pinned).map(\.id)) }

    /// The centre, in SwiftUI coordinates, of the slot at this index.
    private func slotCenterY(_ index: Int) -> CGFloat {
        fanRect.minY - content.layout.scroll + CGFloat(index) * content.layout.tabStep + metrics.tabHeight / 2
    }

    /// Where the lifted tab would land: the slot nearest its centre,
    /// inside its group (`DeckReorder`).
    private func projectedIndex(for drag: DeckDrag) -> Int? {
        let step = max(content.layout.tabStep, 1)
        let nearest = Int(((drag.centerY - slotCenterY(0)) / step).rounded())
        return DeckReorder.clampedIndex(nearest, for: drag.id, in: order, pinned: pinnedIDs)
    }

    /// Where the lifted tab shows: at its centre, held to its group's ends
    /// with a little give past them, so the boundary is felt, not hit.
    private func displayedCenterY(for drag: DeckDrag) -> CGFloat {
        guard let first = DeckReorder.clampedIndex(Int.min, for: drag.id, in: order, pinned: pinnedIDs),
              let last = DeckReorder.clampedIndex(Int.max, for: drag.id, in: order, pinned: pinnedIDs) else { return drag.centerY }
        let low = slotCenterY(first)
        let high = slotCenterY(last)
        if drag.centerY < low { return low + (drag.centerY - low) * 0.25 }
        if drag.centerY > high { return high + (drag.centerY - high) * 0.25 }
        return drag.centerY
    }

    private var placedTabs: [Placement] {
        let tabs = content.layout.tabs
        var projected = order
        var lifted: NoteID?
        var liftedCenter: CGFloat = 0
        if let drag = activeDrag, let target = projectedIndex(for: drag) {
            projected = DeckReorder.moved(drag.id, to: target, in: projected, pinned: pinnedIDs) ?? projected
            lifted = drag.id
            liftedCenter = displayedCenterY(for: drag)
        }
        return tabs.enumerated().map { index, tab in
            let slot = projected.firstIndex(of: tab.id) ?? index
            if tab.id == lifted {
                // Back to AppKit's y for the frame the tab draws at.
                let frame = CGRect(x: tab.frame.minX, y: height - liftedCenter - tab.frame.height / 2, width: tab.frame.width, height: tab.frame.height)
                return Placement(id: tab.id, tab: tab, slot: slot, frame: frame, lifted: true)
            }
            return Placement(id: tab.id, tab: tab, slot: slot, frame: tabs[slot].frame, lifted: false)
        }
    }

    // MARK: - Notices

    /// A refused drop, while it hovers: the read-only line with its lock,
    /// where the archive toast goes.
    private func dropNotice(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: Brand.Space.s8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Brand.coral)
                .padding(.top, 1)
            Text(notice)
                .font(Brand.mono(10))
                .foregroundStyle(Color.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Brand.Space.s12)
        .padding(.vertical, Brand.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(content.side == .right ? .trailing : .leading, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop refused: \(notice)")
    }

    // MARK: - Tabs

    /// One tab: a press-and-release opens the note; a press moved past
    /// `DeckMetrics.dragThreshold` along the deck lifts it — never while
    /// read-only, never at rest (the fan opens under the pointer first) —
    /// and the release drops it where the gap is. VoiceOver gets the same
    /// as actions: the note, Move up and Move down.
    private func tabView(_ placement: Placement, progress: MarkdownLite.ChecklistProgress?) -> some View {
        let tab = placement.tab
        let note = content.notes.first { $0.id == tab.id }
        let isOpen = content.state.openNote == tab.id
        let lifted = placement.lifted
        let isHovered = (hovered == tab.id || content.staticHover == tab.id) && !lifted
        let isTicked = ticked == tab.id
        let canMove = !content.readOnly && order.count > 1 && !atRest
        // A note iCloud has not downloaded is only its file name: greyed.
        let downloading = note.map { $0.isDownloading && !$0.bodyIsLoaded } ?? false
        // Straight when open or lifted; otherwise the note's own lean, a
        // share of it at rest.
        let tilt = DeckTilt.tilt(for: tab.id)
        let straight = isOpen || lifted
        let share: CGFloat = atRest ? metrics.restTilt : 1
        // Out from the edge: the tilt's inset, a hover's lift (in the fan;
        // at rest the tab brightens instead), a lifted tab's, a tick's,
        // and at rest every edge's lift as a drop's target.
        let inward: CGFloat = (straight ? 0 : tilt.inset * share) + (isHovered && !atRest ? 3 : 0) + (lifted ? 4 : 0) + (isTicked ? 3 : 0) + (atRest && content.dropTarget ? 4 : 0)
        let towardsScreen: CGFloat = content.side == .right ? -1 : 1
        // The tab is the note's paper in this appearance, its title in the
        // paper's ink and the note's own font.
        let look = note.map { NoteAppearance.resolve($0, defaults: content.defaults) }
        let label = (note.map { ($0.pinned ? "Pinned note: " : "Note: ") + $0.title } ?? tab.id.rawValue) + (downloading ? ", downloading" : "")
        return TabCard(
            note: note, look: look, title: note?.title ?? tab.id.rawValue, side: content.side, isOpen: isOpen, lifted: lifted, hovered: isHovered, atRest: atRest,
            width: tab.frame.width, bleed: metrics.edgeBleed, height: tab.frame.height, progress: atRest ? nil : progress, ticked: isTicked
        )
        .rotationEffect(.degrees(straight ? 0 : tilt.degrees * share))
        .scaleEffect(lifted ? 1.05 : 1, anchor: content.side == .right ? .trailing : .leading)
        .position(paperCenter(placement.frame))
        .offset(x: inward * towardsScreen)
        .opacity(downloading ? 0.55 : 1)
        .zIndex(lifted ? 1000 : isHovered ? 500 : Double(placement.slot))
        .onHover { inside in
            if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
        }
        .gesture(tabGesture(for: tab, canMove: canMove))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.map { "\(label), \($0.done) of \($0.total) done" } ?? label)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(canMove ? "Drag along the deck to reorder" : "")
        .accessibilityAction { content.onTab(tab.id) }
        .accessibilityActions {
            if canMove {
                Button("Move up") { content.onMove(tab.id, -1) }
                Button("Move down") { content.onMove(tab.id, 1) }
            }
        }
    }

    /// In the deck's own space (the panel, y down), so a tab that moves
    /// under the pointer moves nothing about where the pointer is.
    private func tabGesture(for tab: DeckLayout.Tab, canMove: Bool) -> some Gesture {
        let id = tab.id
        let threshold = metrics.dragThreshold
        return DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard cancelled != id else { return }
                if let current = drag, current.id == id {
                    updateDrag(from: current, to: DeckDrag(id: id, centerY: value.location.y - grab))
                } else if drag == nil, canMove, abs(value.translation.height) >= threshold, let index = order.firstIndex(of: id) {
                    // The controller asks the license now: refused (a
                    // deadline passed since the last render), nothing lifts
                    // and the press goes on as a press.
                    guard content.onTabLifted(id) else { return }
                    // Where in the tab the pointer took it: kept, so the
                    // tab does not jump under the pointer.
                    grab = value.startLocation.y - slotCenterY(index)
                    withAnimation(reduceMotion ? nil : Self.lift) { drag = DeckDrag(id: id, centerY: value.location.y - grab) }
                }
            }
            .onEnded { _ in
                if cancelled == id {
                    cancelled = nil
                    return
                }
                if let current = drag, current.id == id {
                    let target = projectedIndex(for: current)
                    withAnimation(reduceMotion ? nil : Self.lift) { drag = nil }
                    edgeHold.end()
                    content.onTabDropped(target)
                    return
                }
                content.onTab(id)
            }
    }

    /// The gap moves with a spring; the tab itself follows the pointer as
    /// it is. Held at the fan's end, the fan scrolls under it.
    private func updateDrag(from current: DeckDrag, to moved: DeckDrag) {
        if projectedIndex(for: moved) != projectedIndex(for: current) {
            withAnimation(reduceMotion ? nil : Self.lift) { drag = moved }
        } else {
            drag = moved
        }
        updateEdgeHold(for: moved)
    }

    /// Within a quarter tab of an end with more beyond it, the fan scrolls
    /// under the held tab on a timer (`DeckAutoScroll`) until the tab
    /// moves away, the end is reached, or the tab is dropped.
    private func updateEdgeHold(for drag: DeckDrag) {
        let direction = DeckAutoScroll.direction(tabCenterY: drag.centerY, fan: fanRect, canScrollUp: content.layout.canScrollUp, canScrollDown: content.layout.canScrollDown, metrics: metrics)
        edgeHold.moved(to: direction, onScroll: content.onScroll)
    }

    /// The `+` tab: a neutral paper under the fan, its edge at rest like
    /// the notes' (an empty deck at rest is this edge alone). With the fan
    /// out it is the drop's target, ringed in coral; the lock while
    /// read-only; the folder gone, a warning.
    private var plusTab: some View {
        let rect = content.layout.plusTab
        let target = content.dropTarget && !atRest
        let lift: CGFloat = atRest && content.dropTarget ? 4 : 0
        let towardsScreen: CGFloat = content.side == .right ? -1 : 1
        let glyph = content.folderMissing ? "exclamationmark" : content.readOnly ? "lock" : "plus"
        let label = content.folderMissing ? "OpenNotes: can’t find the notes folder" : content.readOnly ? "Read-only" : "New note"
        return Button(action: content.onPlus) {
            PaperEdge(side: content.side, width: rect.width, bleed: metrics.edgeBleed, height: rect.height, fill: target ? Brand.accentSubtle : content.folderMissing ? Brand.dangerSubtle : Brand.face(.paper), hairline: target ? Brand.coral : Brand.textPrimary.opacity(0.25), hairlineWidth: target ? 1.5 : 0.5, shadowOpacity: lift > 0 ? 0.22 : 0.14, shadowRadius: lift > 0 ? 6 : 4) {
                Image(systemName: glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(content.folderMissing ? Brand.dangerSolid : Brand.textPrimary)
                    .opacity(atRest ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .position(paperCenter(rect))
        .offset(x: lift * towardsScreen)
        .help(content.folderMissing ? label : content.readOnly ? content.readOnlyNotice : "New note")
        .accessibilityLabel(label)
        .accessibilityHint(atRest ? "Move the pointer to the edge to fan the deck out; drop text, a link or files here for a new note" : "")
        .contextMenu {
            Button("All Notes…", action: content.onAllNotes)
        }
    }

    // MARK: - Toast

    private func toast(_ pending: ArchiveUndo.Pending) -> some View {
        HStack(spacing: Brand.Space.s8) {
            Text("Archived “\(pending.title)”")
                .font(Brand.body(12))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Undo", action: content.onUndo)
                .buttonStyle(.plain)
                .font(Brand.body(12, weight: 600))
                .foregroundStyle(Brand.coral)
                .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, Brand.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(content.side == .right ? .trailing : .leading, 6)
        .accessibilityElement(children: .combine)
    }
}

/// One tab as a paper card: the note's paper in this appearance, a
/// hairline in the ink's tone (a light rim on a dark paper) and a soft
/// shadow, which does the separating — no border. In the fan: a bar of
/// the note's colour along its outer edge, the pin when pinned, and the
/// title along the tab — reading down on the right edge, up on the left —
/// cut with an ellipsis. A note with a checklist shows its count (`3/7`)
/// at the tab's foot and a thin line of the note's ink along the inner
/// edge, filled as far as the list has come; the last box done ticks the
/// count once. At rest the paper alone, brightened a little under the
/// pointer. Hover lifts a fanned tab a little, a drag lifts it more.
private struct TabCard: View {
    let note: Note?
    let look: NoteAppearance?
    let title: String
    let side: DeckSide
    let isOpen: Bool
    let lifted: Bool
    let hovered: Bool
    let atRest: Bool
    /// What shows of the tab; `PaperEdge` draws it `bleed` wider.
    let width: CGFloat
    let bleed: CGFloat
    let height: CGFloat
    var progress: MarkdownLite.ChecklistProgress?
    var ticked = false

    /// The paper's ink for the appearance: the title, the pin, the count,
    /// the checklist's line and the hairline.
    private var ink: Color { look?.tabInk ?? Brand.textPrimary }

    var body: some View {
        let raised = lifted || (hovered && !atRest)
        PaperEdge(
            side: side, width: width, bleed: bleed, height: height,
            fill: look?.tab ?? Brand.surface, hairline: ink.opacity(isOpen ? 0.5 : 0.25), hairlineWidth: isOpen ? 1 : 0.5,
            highlight: atRest && hovered ? 0.18 : 0,
            shadowOpacity: lifted ? 0.3 : raised ? 0.2 : 0.14, shadowRadius: lifted ? 10 : raised ? 6 : 4
        ) {
            ZStack {
                // The colour bar, on the edge away from the screen's.
                HStack(spacing: 0) {
                    if side == .right { bar } else { progressLine }
                    Spacer(minLength: 0)
                    if side == .left { bar } else { progressLine }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                // The label runs the tab's length, laid out along it and then
                // turned; the pin sits at the top, above it, the count at the
                // foot, below it.
                let countLength: CGFloat = progress == nil ? 0 : 22
                let labelLength = height - 16 - (note?.pinned == true ? 14 : 0) - countLength
                let across = max(0, width - 12)
                VStack(spacing: 2) {
                    if note?.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.opacity(0.7))
                    }
                    Text(title)
                        .font(look.map { Font($0.nsFont(size: 12.5, weight: 600)) } ?? Brand.body(12.5, weight: 600))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelLength, height: across)
                        .rotationEffect(.degrees(side == .right ? 90 : -90))
                        .frame(width: across, height: labelLength)
                    if let progress {
                        Text(progress.label)
                            .font(Brand.mono(9, medium: true))
                            .foregroundStyle(progress.isComplete ? ink : ink.opacity(0.75))
                            .lineLimit(1)
                            .frame(width: countLength, height: across)
                            .rotationEffect(.degrees(side == .right ? 90 : -90))
                            .frame(width: across, height: countLength)
                            .scaleEffect(ticked ? 1.35 : 1)
                    }
                }
                .padding(.top, 8)
                .padding(side == .right ? .leading : .trailing, 4)
            }
            // The paper alone at rest: what is written on it fades in as
            // the tab widens into the fan.
            .opacity(atRest ? 0 : 1)
        }
    }

    /// The checklist's line: a faint track the tab's length, the done
    /// share filled in the note's ink from the top, 2 pt wide. Nothing
    /// without a checklist.
    @ViewBuilder private var progressLine: some View {
        if let progress {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Capsule().fill(ink.opacity(0.12))
                    Capsule().fill(ink.opacity(progress.isComplete ? 0.9 : 0.7))
                        .frame(height: max(2, geometry.size.height * progress.fraction))
                }
            }
            .frame(width: 2)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 2)
        }
    }

    private var bar: some View {
        Capsule().fill(note.map { Brand.bar($0.color) } ?? Brand.borderControl).frame(width: 3)
    }
}

/// A paper's edge against the screen: the tabs and the `+` tab are both
/// this. Rounded on the side away from the edge and square against it,
/// with continuous corners that follow the width — 6 pt at the rest
/// width, 10 pt at the fan's — drawn `bleed` wider than `width` with the
/// extra past the screen edge, so a tilted, inset or lifted paper never
/// shows the wallpaper between itself and the edge. Filled, hairlined,
/// shadowed; the content sits on the visible part.
private struct PaperEdge<Content: View>: View {
    let side: DeckSide
    let width: CGFloat
    let bleed: CGFloat
    let height: CGFloat
    let fill: Color
    let hairline: Color
    var hairlineWidth: CGFloat = 0.5
    /// A white wash over the paper: brightened under the pointer at rest.
    var highlight: Double = 0
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            shape.fill(fill)
            if highlight > 0 { shape.fill(Color.white.opacity(highlight)) }
            // On the visible part, and cut to it: what is written on a
            // tab is laid out for the fan's width and fades as the tab
            // narrows.
            content
                .frame(width: width, height: height)
                .clipped()
                .padding(side == .right ? .trailing : .leading, bleed)
            shape.strokeBorder(hairline, lineWidth: hairlineWidth)
        }
        .frame(width: width + bleed, height: height)
        .contentShape(shape)
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: side == .right ? -1 : 1, y: 2)
    }

    private var radius: CGFloat { min(10, max(6, width * 0.75)) }

    private var shape: UnevenRoundedRectangle {
        if side == .right {
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
        }
    }
}

/// The edge-hold timer: while a lifted tab is held at an end of the fan
/// (`DeckEdgeHold` says when), the fan scrolls under it every
/// `DeckAutoScroll.interval`. Owned by the deck view's state, so it lives
/// as long as the deck does; ended with the drag.
final class EdgeHoldTimer {
    private var hold = DeckEdgeHold()
    private var timer: Timer?
    private var onScroll: (CGFloat) -> Void = { _ in }

    var isHolding: Bool { hold.isHolding }

    deinit {
        MainActor.assumeIsolated { timer?.invalidate() }
    }

    /// The lifted tab is now at this end (nil: at neither); `onScroll` is
    /// the deck's current scroll, taken afresh each time.
    func moved(to direction: DeckAutoScroll.Direction?, onScroll: @escaping (CGFloat) -> Void) {
        self.onScroll = onScroll
        switch hold.moved(to: direction) {
        case .start(let direction):
            timer?.invalidate()
            let delta = DeckAutoScroll.delta(direction)
            timer = Timer.scheduledTimer(withTimeInterval: DeckAutoScroll.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScroll(delta) }
            }
        case .stop:
            stop()
        case .none:
            break
        }
    }

    /// The tab was dropped, or the drag cancelled.
    func end() {
        if hold.ended() == .stop { stop() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// One note slid out: the editor on the note's paper, the footer with the
/// colour and font menus, pin, archive and the status line.
struct NoteCard: View {
    let note: Note
    let content: DeckContent
    @State private var showsColors = false
    @State private var showsFonts = false
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.colorScheme) private var colorScheme

    private var look: NoteAppearance { NoteAppearance.resolve(note, defaults: content.defaults) }

    var body: some View {
        let look = look
        VStack(spacing: 0) {
            // The trial's remaining time, or why the note is read-only,
            // while there is something to say (official builds).
            LicensePillHeader(license: content.license)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            if note.isDownloading, !note.bodyIsLoaded {
                // Only the file name until iCloud brings the file; opening
                // it asked for the download.
                Text("Downloading…")
                    .font(Font(look.nsFont()))
                    .foregroundStyle(look.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if previewRendering {
                // `ImageRenderer` draws no NSTextView: the styled text, static.
                // As an overlay, so a long note (the welcome note) is cut
                // at the card's edge the way the scroll view cuts it,
                // instead of stretching the card.
                Color.clear
                    .overlay(alignment: .topLeading) {
                        PreviewText(text: note.text, look: look, dark: colorScheme == .dark)
                            .padding(12)
                    }
                    .clipped()
            } else {
                NoteEditor(
                    text: note.text, look: look, isEditable: !content.readOnly && !note.truncated && note.bodyIsLoaded, focusToken: content.focusToken,
                    onTextChange: content.onTextChange, onCommand: content.onCommand, onFocus: content.onFocus, mayEdit: content.mayEdit
                )
            }
            footer(look)
        }
        .background(look.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note: \(note.title)")
    }

    private func footer(_ look: NoteAppearance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The paper: the swatch opens the grid and Custom….
                Button { showsColors.toggle() } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(look.swatch)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                            .frame(width: 14, height: 14)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(look.inkSecondary)
                    }
                }
                .buttonStyle(FooterActionStyle(wide: true))
                .disabled(content.readOnly)
                .help(content.readOnly ? content.readOnlyNotice : "Colour: \(note.color.title)")
                .accessibilityLabel("Colour: \(note.color.title)")
                .popover(isPresented: $showsColors, arrowEdge: .bottom) {
                    ColorChooser(selected: note.color, readOnly: content.readOnly, onPick: { color in
                        content.onColor(color)
                    }, onCustom: {
                        showsColors = false
                        content.onCustomColor()
                    })
                }
                // The font: the faces, any installed family, the size.
                Button { showsFonts.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Aa")
                            .font(Font(look.nsFont(size: 12, weight: 600)))
                            .foregroundStyle(look.ink)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(look.inkSecondary)
                    }
                }
                .buttonStyle(FooterActionStyle(wide: true))
                .disabled(content.readOnly)
                .help(content.readOnly ? content.readOnlyNotice : "Font: \(look.fontTitle) \(Int(look.size)) pt (⌘⇧M switches the face)")
                .accessibilityLabel("Font: \(look.fontTitle)")
                .popover(isPresented: $showsFonts, arrowEdge: .bottom) {
                    FontChooser(
                        selection: note.typeface, size: Int(look.size), ownSize: note.fontSize != nil, readOnly: content.readOnly, offersDefault: true,
                        onPick: { content.onTypeface($0) }, onSize: { content.onFontSize($0) }
                    )
                }
                Spacer(minLength: 4)
                Button(action: content.onPin) {
                    Image(systemName: note.pinned ? "pin.fill" : "pin").foregroundStyle(look.ink)
                }
                .buttonStyle(FooterActionStyle())
                .disabled(content.readOnly)
                .help(note.pinned ? "Unpin (⌘⇧P)" : "Pin to the top (⌘⇧P)")
                .accessibilityLabel(note.pinned ? "Unpin" : "Pin")
                Button(action: content.onArchive) {
                    Image(systemName: "archivebox").foregroundStyle(look.ink)
                }
                .buttonStyle(FooterActionStyle())
                .disabled(content.readOnly)
                .help("Archive (⌘⇧A)")
                .accessibilityLabel("Archive")
            }
            if content.readOnly {
                // The read-only line, and the way to the License section.
                Button(action: content.license.openLicense) {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                        Text(content.statusLine)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .font(Brand.mono(10))
                    .foregroundStyle(look.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Opens License settings")
                .accessibilityLabel("Read-only: \(content.statusLine)")
                .accessibilityHint("Opens License settings")
            } else {
                Text(content.statusLine)
                    .font(Brand.mono(10))
                    .foregroundStyle(look.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = look.missingFontNotice {
                // The file names a font this Mac does not have.
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "textformat").font(.system(size: 9, weight: .semibold))
                    Text(notice)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Brand.mono(10))
                .foregroundStyle(look.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.05))
    }
}

/// The styler's runs as SwiftUI text, for the preview harness and All
/// Notes' preview card.
struct PreviewText: View {
    let text: String
    let look: NoteAppearance
    let dark: Bool

    var body: some View {
        Text(attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        let styler = NoteStyler(look: look, appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
        return styler.previewAttributed(text)
    }
}
