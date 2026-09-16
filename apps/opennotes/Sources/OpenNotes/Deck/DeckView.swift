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
    /// The pill at the top of the open note reads it on every body; the
    /// footer's read-only line opens Settings → License through it.
    var license = LicenseStatus()
    /// A new value puts a lifted tab back where it was (Escape, the note
    /// leaving the deck); nil leaves the drag alone.
    var dragCancelToken = 0
    /// The preview harness: a tab shown lifted, mid-drag, with no pointer.
    var staticDrag: DeckDrag?
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
    var onColor: (NoteColor) -> Void = { _ in }
    var onFace: () -> Void = {}
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

/// The deck: the pill, the fan of tabs, the `+` tab, the open note and
/// the archive toast, each placed by `DeckLayout` (AppKit coordinates,
/// flipped here). Every element animates between layouts. The tabs are
/// separate papers, each at its own small tilt (`DeckTilt`), stacked in
/// a fan that scrolls when they do not fit, fading at whichever end has
/// more beyond it. A tab pressed and moved past the threshold lifts
/// (straight, larger, a deeper shadow) and follows the pointer along the
/// deck while the others slide out of its way (`DeckReorder` says where
/// it may land); the drop asks the controller for the move.
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

    private var height: CGFloat { content.layout.panelFrame.height }
    private static let lift = Animation.spring(response: 0.3, dampingFraction: 0.72)
    private static let space = "deck"
    private var metrics: DeckMetrics { DeckMetrics() }

    var body: some View {
        let placed = placedTabs
        ZStack(alignment: .topLeading) {
            Color.clear
            if content.state == .pill {
                pill
            } else {
                fanBackground
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(placed, id: \.id) { placement in
                        tabView(placement)
                    }
                }
                .frame(width: content.layout.panelFrame.width, height: height, alignment: .topLeading)
                .mask(alignment: .topLeading) { fanMask }
                plusTab
            }
            if let noteRect = content.layout.note, let note = content.openNote {
                NoteCard(note: note, content: content)
                    .frame(width: noteRect.width, height: noteRect.height)
                    .position(center(noteRect))
                    .transition(.move(edge: content.side == .right ? .trailing : .leading).combined(with: .opacity))
            }
            if let toastRect = content.layout.toast, let pending = content.pendingUndo {
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
        .onChange(of: content.dragCancelToken) {
            guard let current = drag else { return }
            cancelled = current.id
            drag = nil
        }
        .onChange(of: content.notes.map(\.id)) {
            guard let current = drag, !content.notes.contains(where: { $0.id == current.id }) else { return }
            cancelled = current.id
            drag = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenNotes deck")
    }

    private func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: height - rect.midY)
    }

    /// Rounded on the side away from the edge, square against it.
    private func edgeShape(radius: CGFloat) -> UnevenRoundedRectangle {
        if content.side == .right {
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
        }
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

    // MARK: - Pill

    private var pill: some View {
        let rect = content.layout.pill
        let dashes = Array(content.notes.prefix(metrics.pillMaxDashes))
        let overflow = content.notes.count - dashes.count
        return ZStack {
            edgeShape(radius: 7).fill(Color.black.opacity(0.62))
            edgeShape(radius: 7).strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            VStack(spacing: 4) {
                if content.folderMissing {
                    Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.coral)
                } else if dashes.isEmpty {
                    Circle().fill(Color.white.opacity(0.5)).frame(width: 4, height: 4)
                }
                ForEach(dashes) { note in
                    Capsule().fill(Brand.tab(note.color)).frame(width: 4, height: 18)
                }
                if overflow > 0 {
                    Circle().fill(Color.white.opacity(0.7)).frame(width: 4, height: 4)
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(center(rect))
        .accessibilityLabel(content.folderMissing ? "OpenNotes: can’t find the notes folder" : "OpenNotes: \(content.notes.count) notes")
        .accessibilityHint("Move the pointer to the edge to fan the deck out")
    }

    // MARK: - Tabs

    /// One tab: a press-and-release opens the note; a press moved past
    /// `DeckMetrics.dragThreshold` along the deck lifts it — never while
    /// read-only — and the release drops it where the gap is. VoiceOver
    /// gets the same as actions: the note, Move up and Move down.
    private func tabView(_ placement: Placement) -> some View {
        let tab = placement.tab
        let note = content.notes.first { $0.id == tab.id }
        let isOpen = content.state.openNote == tab.id
        let lifted = placement.lifted
        let isHovered = hovered == tab.id && !lifted
        let canMove = !content.readOnly && order.count > 1
        // Straight when open or lifted; otherwise the note's own lean.
        let tilt = DeckTilt.tilt(for: tab.id)
        let straight = isOpen || lifted
        let inward: CGFloat = (straight ? 0 : tilt.inset) + (isHovered ? 3 : 0) + (lifted ? 4 : 0)
        let towardsScreen: CGFloat = content.side == .right ? -1 : 1
        return TabCard(note: note, title: note?.title ?? tab.id.rawValue, side: content.side, isOpen: isOpen, lifted: lifted, hovered: isHovered, width: tab.frame.width, height: tab.frame.height)
            .rotationEffect(.degrees(straight ? 0 : tilt.degrees))
            .scaleEffect(lifted ? 1.05 : 1, anchor: content.side == .right ? .trailing : .leading)
            .position(center(placement.frame))
            .offset(x: inward * towardsScreen)
            .zIndex(lifted ? 1000 : isHovered ? 500 : Double(placement.slot))
            .onHover { inside in
                if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
            }
            .gesture(tabGesture(for: tab, canMove: canMove))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note.map { ($0.pinned ? "Pinned note: " : "Note: ") + $0.title } ?? tab.id.rawValue)
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
        let rect = fanRect
        let edge = metrics.tabHeight / 4
        if moved.centerY - metrics.tabHeight / 2 < rect.minY + edge, content.layout.canScrollUp {
            content.onScroll(-8)
        } else if moved.centerY + metrics.tabHeight / 2 > rect.maxY - edge, content.layout.canScrollDown {
            content.onScroll(8)
        }
    }

    private var plusTab: some View {
        let rect = content.layout.plusTab
        return Button(action: content.onPlus) {
            ZStack {
                edgeShape(radius: 10).fill(Brand.canvas.opacity(0.92))
                edgeShape(radius: 10).strokeBorder(Brand.borderSubtle, lineWidth: 1)
                Image(systemName: content.readOnly ? "lock" : "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .frame(width: rect.width, height: rect.height)
        .position(center(rect))
        .help(content.readOnly ? content.readOnlyNotice : "New note")
        .accessibilityLabel(content.readOnly ? "Read-only" : "New note")
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

/// One tab as a paper card: the note's face with a hairline edge and a
/// soft shadow, a bar of the note's colour along its outer edge, the pin
/// when pinned, and the title along the tab — reading down on the right
/// edge, up on the left — cut with an ellipsis. Hover lifts it a little,
/// a drag lifts it more.
private struct TabCard: View {
    let note: Note?
    let title: String
    let side: DeckSide
    let isOpen: Bool
    let lifted: Bool
    let hovered: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let ink = Color(nsColor: NSColor(hex: 0x141414))
        let shadowOpacity = lifted ? 0.3 : hovered ? 0.2 : 0.14
        let shadowRadius: CGFloat = lifted ? 10 : hovered ? 6 : 4
        ZStack {
            shape.fill(note.map { Brand.tab($0.color) } ?? Brand.surface)
            // The colour bar, on the edge away from the screen's.
            HStack(spacing: 0) {
                if side == .right { bar }
                Spacer(minLength: 0)
                if side == .left { bar }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            shape.strokeBorder(Color.black.opacity(isOpen ? 0.45 : 0.16), lineWidth: isOpen ? 1.5 : 1)
            // The label runs the tab's length, laid out along it and then
            // turned; the pin sits at the top, above it.
            let labelLength = height - 16 - (note?.pinned == true ? 14 : 0)
            VStack(spacing: 2) {
                if note?.pinned == true {
                    Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.opacity(0.7))
                }
                Text(title)
                    .font(Brand.body(12.5, weight: 600))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelLength, height: width - 12)
                    .rotationEffect(.degrees(side == .right ? 90 : -90))
                    .frame(width: width - 12, height: labelLength)
            }
            .padding(.top, 8)
            .padding(side == .right ? .leading : .trailing, 4)
        }
        .frame(width: width, height: height)
        .contentShape(shape)
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: side == .right ? -1 : 1, y: 2)
    }

    private var shape: UnevenRoundedRectangle {
        if side == .right {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 10, topTrailingRadius: 10, style: .continuous)
        }
    }

    private var bar: some View {
        Capsule().fill(note.map { Brand.bar($0.color) } ?? Brand.borderControl).frame(width: 3)
    }
}

/// One note slid out: the editor on the note's face, the footer with the
/// colors, the face, pin, archive and the status line.
struct NoteCard: View {
    let note: Note
    let content: DeckContent
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // The trial's remaining time, or why the note is read-only,
            // while there is something to say (official builds).
            LicensePillHeader(license: content.license)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            if previewRendering {
                // `ImageRenderer` draws no NSTextView: the styled text, static.
                // As an overlay, so a long note (the welcome note) is cut
                // at the card's edge the way the scroll view cuts it,
                // instead of stretching the card.
                Color.clear
                    .overlay(alignment: .topLeading) {
                        PreviewText(text: note.text, face: note.face, dark: colorScheme == .dark)
                            .padding(12)
                    }
                    .clipped()
            } else {
                NoteEditor(
                    text: note.text, face: note.face, isEditable: !content.readOnly && !note.truncated && note.bodyIsLoaded, focusToken: content.focusToken,
                    onTextChange: content.onTextChange, onCommand: content.onCommand, onFocus: content.onFocus, mayEdit: content.mayEdit
                )
            }
            footer
        }
        .background(Brand.face(note.color), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note: \(note.title)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Button { content.onColor(color) } label: {
                        Circle()
                            .fill(Brand.tab(color))
                            .overlay(Circle().strokeBorder(Color.black.opacity(note.color == color ? 0.7 : 0.15), lineWidth: note.color == color ? 2 : 1))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(content.readOnly)
                    .help(color.title)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(note.color == color ? .isSelected : [])
                }
                Spacer(minLength: 4)
                Button(action: content.onFace) {
                    Text(note.face == .sans ? "Aa" : "{}")
                        .font(note.face == .sans ? Brand.body(12, weight: 600) : Brand.mono(11, medium: true))
                        .foregroundStyle(Brand.noteInk)
                }
                .buttonStyle(FooterActionStyle())
                .disabled(content.readOnly)
                .help(note.face == .sans ? "Switch to Mono (⌘⇧M)" : "Switch to Sans (⌘⇧M)")
                .accessibilityLabel("Face: \(note.face.title)")
                Button(action: content.onPin) {
                    Image(systemName: note.pinned ? "pin.fill" : "pin").foregroundStyle(Brand.noteInk)
                }
                .buttonStyle(FooterActionStyle())
                .disabled(content.readOnly)
                .help(note.pinned ? "Unpin (⌘⇧P)" : "Pin to the top (⌘⇧P)")
                .accessibilityLabel(note.pinned ? "Unpin" : "Pin")
                Button(action: content.onArchive) {
                    Image(systemName: "archivebox").foregroundStyle(Brand.noteInk)
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
                    .foregroundStyle(Brand.noteInkSecondary)
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
                    .foregroundStyle(Brand.noteInkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.05))
    }
}

/// The styler's runs as SwiftUI text, for the preview harness only.
struct PreviewText: View {
    let text: String
    let face: NoteFace
    let dark: Bool

    var body: some View {
        Text(attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        let styler = NoteStyler(face: face, appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
        let storage = NSTextStorage(string: text)
        styler.apply(to: storage)
        return AttributedString(storage)
    }
}
