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
    var onTab: (NoteID) -> Void = { _ in }
    var onPlus: () -> Void = {}
    var onMore: () -> Void = {}
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

/// The deck: the pill, the fan of tabs, the `+` tab, the open note and
/// the archive toast, each placed by `DeckLayout` (AppKit coordinates,
/// flipped here). Every element animates between layouts.
struct DeckView: View {
    let content: DeckContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewRendering) private var previewRendering

    private var height: CGFloat { content.layout.panelFrame.height }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if content.state == .pill {
                pill
            } else {
                ForEach(Array(content.layout.tabs.enumerated()), id: \.offset) { index, tab in
                    tabView(tab, index: index)
                }
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
        .animation(reduceMotion ? nil : .easeOut(duration: Brand.Motion.standard), value: content.state)
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

    // MARK: - Pill

    private var pill: some View {
        let rect = content.layout.pill
        let dashes = Array(content.notes.prefix(DeckMetrics().maxTabs))
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

    private func tabView(_ tab: DeckLayout.Tab, index: Int) -> some View {
        let note = tab.id.flatMap { id in content.notes.first { $0.id == id } }
        let isOpen = content.state.openNote != nil && content.state.openNote == tab.id
        let label = note.map(\.title) ?? "+\(tab.more) more"
        return Button {
            if let id = tab.id { content.onTab(id) } else { content.onMore() }
        } label: {
            ZStack {
                edgeShape(radius: 10)
                    .fill(note.map { Brand.tab($0.color) } ?? Brand.surface)
                    .shadow(color: .black.opacity(isOpen ? 0.18 : 0.1), radius: isOpen ? 6 : 3, x: content.side == .right ? -2 : 2, y: 2)
                edgeShape(radius: 10).strokeBorder(Color.black.opacity(isOpen ? 0.5 : 0.08), lineWidth: isOpen ? 1.5 : 1)
                // The label lives in the part the next tab never covers
                // (the top, above the overlap), laid out along the tab and
                // then turned: it reads down on the right edge, up on the left.
                let labelLength = max(24, content.layout.tabStep - 12)
                VStack(spacing: 3) {
                    if note?.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(nsColor: NSColor(hex: 0x141414)).opacity(0.7))
                    }
                    Text(label)
                        .font(Brand.body(11, weight: 600))
                        .foregroundStyle(Color(nsColor: NSColor(hex: 0x141414)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelLength - (note?.pinned == true ? 14 : 0), height: tab.frame.width - 8)
                        .rotationEffect(.degrees(content.side == .right ? 90 : -90))
                        .frame(width: tab.frame.width - 8, height: labelLength - (note?.pinned == true ? 14 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
        .buttonStyle(.plain)
        .frame(width: tab.frame.width, height: tab.frame.height)
        .position(center(tab.frame))
        .zIndex(Double(index))
        .accessibilityLabel(note.map { "Note: \($0.title)" } ?? label)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
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

/// One note slid out: the editor on the note's face, the footer with the
/// colors, the face, pin, archive and the status line.
struct NoteCard: View {
    let note: Note
    let content: DeckContent
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if previewRendering {
                // `ImageRenderer` draws no NSTextView: the styled text, static.
                PreviewText(text: note.text, face: note.face, dark: colorScheme == .dark)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                NoteEditor(
                    text: note.text, face: note.face, isEditable: !content.readOnly && !note.truncated, focusToken: content.focusToken,
                    onTextChange: content.onTextChange, onCommand: content.onCommand, onFocus: content.onFocus
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
                .help("Archive (⌘⇧A)")
                .accessibilityLabel("Archive")
            }
            Text(content.statusLine)
                .font(Brand.mono(10))
                .foregroundStyle(Brand.noteInkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
