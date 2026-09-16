import AppKit
import OpenNotesCore
import SwiftUI
import UniformTypeIdentifiers

final class AllNotesWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let openNote: (NoteID) -> Void
    /// Made on the first `show()`; replaced when the screen-sharing
    /// setting turns off (`applyScreenSharing`).
    private(set) var window: NSWindow?
    /// The search, the filter and the selection, kept across a replacement.
    let session = AllNotesSession()
    /// The window's frame is remembered under this name between launches;
    /// nil remembers nothing (the tests, which must write no defaults).
    var frameAutosaveName: NSWindow.FrameAutosaveName? = "AllNotes"

    init(model: AppModel, openNote: @escaping (NoteID) -> Void) {
        self.model = model
        self.openNote = openNote
        super.init()
        // "Keep notes out of screen sharing": the window shows note text, so
        // it follows the setting like the deck.
        observeChanges({ [model] in _ = model.preferences.hideFromScreenSharing }, onChange: { [weak self] in self?.applyScreenSharing() })
    }

    func show() {
        if window == nil { makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window, not yet on screen; `show()` orders it front. Centred
    /// on the first make (the autosaved frame, if any, then takes over);
    /// `frame` puts a replacement exactly where the window it replaces was.
    func makeWindow(frame: CGRect? = nil) {
        let root = AllNotesView(model: model, openNote: openNote, export: { [weak self] id, format in self?.export(id, as: format) }, session: session)
        let hostingView = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: frame ?? NSRect(origin: .zero, size: NSSize(width: 800, height: 540)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "All Notes"
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        if let frameAutosaveName { window.setFrameAutosaveName(frameAutosaveName) }
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        ScreenSharing.apply(to: window, surface: .allNotes, hidden: model.preferences.hideFromScreenSharing)
        self.window = window
    }

    /// The setting changed: the window follows. Turned off, a window once
    /// hidden cannot be shown again (`ScreenSharing`): one made anew takes
    /// its place — the same frame, the same search, filter and selection
    /// (`session`) — on screen if the old one was, without taking the
    /// focus from Settings.
    private func applyScreenSharing() {
        guard let window else { return }
        guard !ScreenSharing.apply(to: window, surface: .allNotes, hidden: model.preferences.hideFromScreenSharing) else { return }
        let wasVisible = window.isVisible
        let frame = window.frame
        window.orderOut(nil)
        makeWindow(frame: frame)
        if wasVisible { self.window?.orderFront(nil) }
    }

    /// Export… through the save panel; works while read-only.
    private func export(_ id: NoteID, as format: ExportFormat) {
        guard let file = try? model.export(id, as: format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? file.data.write(to: url, options: .atomic)
    }
}

/// What the user has set up in All Notes — the search text, Active or
/// Archived, the selected note — kept apart from the view so it outlives
/// the window (`AllNotesWindowController.applyScreenSharing`).
@Observable
final class AllNotesSession {
    var query = ""
    var showsArchived = false
    var selection: NoteID?
}

/// The sidebar (search with the count inside, Active / Archived, the list
/// with drag-to-reorder, the license card while read-only) and the preview
/// pane: the note's state, its actions as chips, the pill, and the note
/// drawn as its own paper on the window's ground
/// (design/products/opennotes.md, "All Notes").
struct AllNotesView: View {
    let model: AppModel
    let openNote: (NoteID) -> Void
    let export: (NoteID, ExportFormat) -> Void
    /// The search, the Active / Archived choice and the selection: owned
    /// by the controller, so a window made anew (the screen-sharing
    /// setting turning off) shows the same list.
    @Bindable var session: AllNotesSession
    @State private var hovered: NoteID?
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.colorScheme) private var colorScheme

    /// The sidebar's width in the harness and its ideal width in the window.
    static let sidebarWidth: CGFloat = 300

    /// `session` is the controller's, or a fresh one whose `query` is what
    /// the search field starts with (the harness's no-results stage).
    init(model: AppModel, openNote: @escaping (NoteID) -> Void, export: @escaping (NoteID, ExportFormat) -> Void, session: AllNotesSession = AllNotesSession()) {
        self.model = model
        self.openNote = openNote
        self.export = export
        self.session = session
    }

    private var query: String { session.query }
    private var showsArchived: Bool { session.showsArchived }
    private var selection: NoteID? { session.selection }

    private var notes: [Note] {
        model.search(query, archived: showsArchived)
    }

    private var selected: Note? {
        (selection.flatMap { model.note($0) } ?? notes.first).flatMap { model.body(of: $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if previewRendering {
                    // `ImageRenderer` draws no split view: a fixed split.
                    HStack(spacing: 0) {
                        sidebar.frame(width: Self.sidebarWidth)
                        Divider()
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    HSplitView {
                        sidebar.frame(minWidth: 260, idealWidth: Self.sidebarWidth, maxWidth: 440)
                        preview.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            // iCloud's state while the folder is iCloud's: one line under
            // the split, nothing otherwise.
            if let line = model.storageStatusLine {
                Divider()
                StorageStatusRow(line: line)
                    .padding(.horizontal, Brand.Space.s16)
                    .padding(.vertical, Brand.Space.s8)
            }
            // An update asking for something (official builds): one line
            // under the split, nothing otherwise.
            if model.updates.hint() != nil {
                Divider()
                UpdateHintRow(updates: model.updates)
                    .padding(.horizontal, Brand.Space.s16)
                    .padding(.vertical, Brand.Space.s8)
            }
        }
        .background(Brand.canvas)
        .tint(Brand.accentSolid)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: Brand.Space.s8) {
                searchField
                HStack(spacing: Brand.Space.s4) {
                    scopeChip("Active", archived: false)
                    scopeChip("Archived", archived: true)
                    Spacer(minLength: 0)
                }
            }
            .padding(Brand.Space.s12)
            // Why the notes are read-only, in LICENSING.md's words with the
            // way out, above the list it gates. Asked on every body.
            if model.license.restriction() != nil {
                LicenseCard(license: model.license)
                    .padding(.horizontal, Brand.Space.s12)
                    .padding(.bottom, Brand.Space.s12)
            }
            if notes.isEmpty {
                Spacer(minLength: 0)
            } else if previewRendering {
                VStack(spacing: 0) {
                    ForEach(notes) { note in
                        row(note)
                            .background(rowBackground(note))
                            .padding(.horizontal, Brand.Space.s8)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                List(selection: $session.selection) {
                    ForEach(notes) { note in
                        row(note)
                            .tag(note.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            // Drawn over the table's own highlight: the
                            // selection is a tint of the accent, hover the
                            // surface, never the system blue.
                            .listRowBackground(
                                rowBackground(note)
                                    .padding(.horizontal, Brand.Space.s8)
                                    .background(Brand.canvas)
                            )
                            .onHover { inside in hovered = inside ? note.id : (hovered == note.id ? nil : hovered) }
                    }
                    .onMove { source, destination in
                        // The drop asks the license (`AppModel.reorder`); the
                        // list is not moveable while read-only regardless.
                        guard !showsArchived, query.isEmpty, !model.readOnly else { return }
                        var ids = notes.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        model.reorder(ids)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Brand.canvas)
                .accessibilityLabel(showsArchived ? "Archived notes" : "Active notes")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            if previewRendering {
                Text(query.isEmpty ? "Search" : query)
                    .font(Brand.body(13))
                    .foregroundStyle(query.isEmpty ? Brand.textSecondary : Brand.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField("Search", text: $session.query)
                    .textFieldStyle(.plain)
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityLabel("Search notes")
            }
            if let count = AllNotesText.count(notes.count) {
                Text(count)
                    .font(Brand.body(11))
                    .monospacedDigit()
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
    }

    /// Active / Archived: the chosen one carries the accent.
    private func scopeChip(_ title: String, archived: Bool) -> some View {
        let selected = showsArchived == archived
        return Button {
            session.showsArchived = archived
            session.selection = nil
        } label: {
            Text(title)
        }
        .buttonStyle(ChipButtonStyle(tone: selected ? .selected : .quiet))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The selection is the accent's tint: the subtle token in light, and
    /// in dark a wash of the solid over the canvas, since the dark subtle
    /// token is the coral paper itself and a row must not read as one.
    private func rowBackground(_ note: Note) -> some View {
        let selectedRow = selected?.id == note.id
        let selection = colorScheme == .dark ? Brand.accentSolid.opacity(0.14) : Brand.accentSubtle
        return RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
            .fill(selectedRow ? selection : hovered == note.id ? Brand.surface : Color.clear)
            .animation(.easeOut(duration: Brand.Motion.fast), value: selectedRow)
    }

    /// The color as the deck's pill dash, the title with the pin, the age,
    /// the title and the first line in the note's own font. A note iCloud
    /// has not downloaded is only its file name: greyed, "Downloading…"
    /// where the preview line goes, a cloud glyph in place of the age.
    private func row(_ note: Note) -> some View {
        let look = model.appearance(of: note)
        let downloading = note.isDownloading && !note.bodyIsLoaded
        return HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(look.swatch)
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                .frame(width: 4, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(note.title)
                        .font(Font(look.nsFont(size: 13, weight: 600)))
                        .foregroundStyle(downloading ? Brand.textSecondary : Brand.textPrimary)
                        .lineLimit(1)
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Brand.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: Brand.Space.s8)
                    if downloading {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.textSecondary)
                            .accessibilityHidden(true)
                    } else {
                        Text(Age.text(note.modified))
                            .font(Brand.body(11))
                            .monospacedDigit()
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(downloading ? "Downloading…" : (note.preview.isEmpty ? " " : note.preview))
                    .font(Font(look.nsFont(size: 12)))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !note.archived { openNote(note.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AllNotesText.rowLabel(note))
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Brand.Space.s8) {
                if let note = selected {
                    Circle()
                        .fill(model.appearance(of: note).swatch)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(AllNotesText.caption(note))
                        .font(Brand.body(11, weight: 600))
                        .tracking(0.8)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // The trial's remaining time, or why the notes are
                // read-only, beside the actions it gates (official builds;
                // nothing while licensed).
                LicensePillHeader(license: model.license)
            }
            .frame(height: 22)
            .padding(.horizontal, Brand.Space.s16)
            .padding(.top, Brand.Space.s12)
            if let note = selected {
                actions(note)
                    .padding(.horizontal, Brand.Space.s16)
                    .padding(.top, Brand.Space.s8)
                Group {
                    if previewRendering {
                        paper(note)
                            .padding(Brand.Space.s16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            paper(note)
                                .padding(Brand.Space.s16)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    /// Open (Restore for an archived note) carries the accent; the rest are
    /// quiet chips, with their words while the pane is wide enough and as
    /// icons with help tags when it is not.
    private func actions(_ note: Note) -> some View {
        ViewThatFits(in: .horizontal) {
            actionRow(note, compact: false)
            actionRow(note, compact: true)
        }
    }

    private func actionRow(_ note: Note, compact: Bool) -> some View {
        HStack(spacing: 6) {
            if note.archived {
                Button("Restore") { model.unarchive(note.id) }
                    .buttonStyle(ChipButtonStyle(tone: .primary))
                    .disabled(model.readOnly)
            } else {
                Button("Open") { openNote(note.id) }
                    .buttonStyle(ChipButtonStyle(tone: .primary))
                    .keyboardShortcut(.defaultAction)
                chip(note.pinned ? "Unpin" : "Pin", symbol: note.pinned ? "pin.slash" : "pin", compact: compact) { model.setPinned(!note.pinned, for: note.id) }
                    .disabled(model.readOnly)
                chip("Archive", symbol: "archivebox", compact: compact) { model.archive(note.id) }
                    .disabled(model.readOnly)
            }
            Spacer(minLength: 0)
            // Nothing to export while the body is not here (a note not
            // downloaded, or unreadable): the store refuses too, so the
            // name never goes out as text.
            if previewRendering {
                chip("Export…", symbol: "square.and.arrow.up", compact: compact) {}
                    .disabled(!note.bodyIsLoaded)
            } else {
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(format.title) { export(note.id, format) }
                    }
                } label: {
                    chipLabel("Export…", symbol: "square.and.arrow.up", compact: compact)
                }
                .menuStyle(.button)
                .buttonStyle(ChipButtonStyle(tone: .quiet))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!note.bodyIsLoaded)
                .help("Export…")
                .accessibilityLabel("Export…")
            }
            chip("Reveal in Finder", symbol: "folder", compact: compact) { model.revealInFinder(note.id) }
        }
    }

    private func chip(_ title: String, symbol: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, symbol: symbol, compact: compact)
        }
        .buttonStyle(ChipButtonStyle(tone: .quiet))
        .help(title)
        .accessibilityLabel(title)
    }

    private func chipLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            if !compact { Text(title) }
        }
    }

    /// The note as the deck shows it: the same paper, ink, font, corner
    /// and contact shadow as the docked card (`model.appearance(of:)`),
    /// with what the file knows in the footer band.
    private func paper(_ note: Note) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let dark = colorScheme == .dark
        let look = model.appearance(of: note)
        return VStack(alignment: .leading, spacing: 0) {
            if note.isDownloading, !note.bodyIsLoaded {
                // Selecting asked iCloud for the file; the text follows
                // once it is here.
                Text(model.statusLine(for: note.id))
                    .font(Font(look.nsFont()))
                    .foregroundStyle(look.inkSecondary)
                    .padding(Brand.Space.s16)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                PreviewText(text: note.text, look: look, dark: dark)
                    .padding(Brand.Space.s16)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            }
            HStack(spacing: Brand.Space.s8) {
                Text(AllNotesText.footer(note, missingFamily: look.missingFamily))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(AllNotesText.faceLabel(look))
                    .fixedSize()
            }
            .font(Brand.body(11))
            .foregroundStyle(look.inkSecondary)
            .padding(.horizontal, Brand.Space.s16)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.05))
        }
        .background(look.paper)
        .clipShape(shape)
        .overlay(shape.strokeBorder(dark ? look.swatch.opacity(0.28) : Color.black.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 12, x: 0, y: 5)
        .frame(maxWidth: 600, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note: \(note.title)")
    }

    private var emptyState: some View {
        let copy = AllNotesText.empty(query: query, archived: showsArchived)
        return VStack(spacing: Brand.Space.s4) {
            Text(copy.title)
                .font(Brand.body(13, weight: 600))
                .foregroundStyle(Brand.textPrimary)
            Text(copy.detail)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Brand.Space.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A small action: the accent for the one primary action, a quiet surface
/// for the rest, the accent's tint for a chosen scope. Press feedback is a
/// small scale, disabled a fade.
struct ChipButtonStyle: ButtonStyle {
    enum Tone { case primary, quiet, selected }

    let tone: Tone
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(12, weight: tone == .quiet ? 500 : 600))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch tone {
        case .primary: Brand.accentOn
        case .quiet: Brand.textPrimary
        case .selected: Brand.accentText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch tone {
        case .primary: pressed ? Brand.accentSolid.opacity(0.85) : Brand.accentSolid
        case .quiet: pressed ? Brand.hover : Brand.surface
        case .selected: Brand.accentSubtle
        }
    }
}

/// The words All Notes derives from a note and a state; pure, so the
/// tests read them without a window.
enum AllNotesText {
    /// The count inside the search field; nothing while the list is empty
    /// (the pane says why).
    static func count(_ notes: Int) -> String? {
        switch notes {
        case 0: nil
        case 1: "1 note"
        default: "\(notes) notes"
        }
    }

    /// The state caption over the actions.
    static func caption(_ note: Note) -> String {
        if note.archived { return "ARCHIVED" }
        return note.pinned ? "PINNED · IN THE DECK" : "ACTIVE · IN THE DECK"
    }

    /// "Edited 5 min ago", "Edited just now", "Edited Mar 4".
    static func edited(_ date: Date, now: Date = Date()) -> String {
        let age = Age.text(date, now: now)
        if age == "now" { return "Edited just now" }
        if now.timeIntervalSince(date) < 7 * 86_400 { return "Edited \(age) ago" }
        return "Edited \(age)"
    }

    /// The paper's footer: when it was created and edited, its file, and
    /// whether what is shown is the whole of it.
    static func footer(_ note: Note, missingFamily: String? = nil, now: Date = Date()) -> String {
        var parts = ["Created \(note.created.formatted(date: .abbreviated, time: .omitted))", edited(note.modified, now: now), note.id.fileName]
        if note.truncated {
            parts.append("over 1 MB; shown from the start, read-only")
        } else if note.isDownloading, !note.bodyIsLoaded {
            parts.append("not downloaded yet")
        } else if !note.bodyIsLoaded {
            parts.append("can’t read the file right now; shown in part")
        }
        if let missingFamily {
            parts.append("“\(missingFamily)” isn’t installed here")
        }
        return parts.joined(separator: " · ")
    }

    /// The footer's end: the font the note is shown in, with its own size
    /// when the file names one ("Sans", "Georgia 14 pt").
    static func faceLabel(_ look: NoteAppearance) -> String {
        look.fontSize.map { "\(look.fontTitle) \($0) pt" } ?? look.fontTitle
    }

    /// What the pane says while there is nothing to show.
    static func empty(query: String, archived: Bool) -> (title: String, detail: String) {
        if !query.isEmpty {
            return ("No matches", "Nothing \(archived ? "archived" : "in the deck") contains “\(query)”.")
        }
        if archived {
            return ("Nothing archived", "Archived notes leave the deck and wait here; Restore brings one back.")
        }
        return ("No notes yet", "Press the hotkey in any app, or click + on the deck.")
    }

    /// The row for VoiceOver: the title, pinned, the age.
    static func rowLabel(_ note: Note, now: Date = Date()) -> String {
        let state = note.isDownloading && !note.bodyIsLoaded ? "downloading" : Age.text(note.modified, now: now)
        return [note.title, note.pinned ? "pinned" : nil, state].compactMap { $0 }.joined(separator: ", ")
    }
}
