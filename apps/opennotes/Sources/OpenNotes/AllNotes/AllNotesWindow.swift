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
    /// The search, the filter, the selection and the checked set, kept
    /// across a replacement.
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
        let root = AllNotesView(
            model: model,
            openNote: openNote,
            export: { [weak self] id, format in self?.export(id, as: format) },
            exportMany: { [weak self] ids, format in self?.export(ids, as: format) },
            session: session
        )
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

    /// Export… on the checked set: a folder from the open panel, then one
    /// file per note in it (`AllNotesExport.write`: no name written twice,
    /// nothing written over).
    /// A note whose body is not here is skipped and said so in the
    /// footer, like any refused bulk action. Works while read-only.
    private func export(_ ids: [NoteID], as format: ExportFormat) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the \(ids.count == 1 ? "note" : "\(ids.count) notes")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var outcome = AppModel.BulkOutcome()
        var notes: [Note] = []
        for id in ids {
            guard let note = model.body(of: id), note.bodyIsLoaded else {
                outcome.skipped.append(.init(id: id, reason: StoreError.bodyUnavailable(id).localizedDescription))
                continue
            }
            notes.append(note)
        }
        let written = AllNotesExport.write(notes, as: format, into: folder)
        outcome.done += written.done
        outcome.skipped += written.skipped
        session.show(AllNotesNotice.refusals(in: outcome))
    }
}

/// What the user has set up in All Notes — the search text, Active or
/// Archived, the previewed note, the checked notes and the last action's
/// footer — kept apart from the view so it outlives the window
/// (`AllNotesWindowController.applyScreenSharing`).
@Observable
final class AllNotesSession {
    var query = ""
    var showsArchived = false
    /// The previewed note (the list's own selection); never moved by a
    /// checkbox.
    var selection: NoteID?
    /// The checked notes: any checked raises the selection bar at the
    /// foot of the list.
    var selected = AllNotesSelection()
    /// The line under the split after a bulk action; nil for none.
    private(set) var notice: AllNotesNotice?
    /// The archived notes Delete… asks about; the sheet while non-nil.
    var pendingDelete: [NoteID]?
    @ObservationIgnored private var noticeTimer: Timer?
    /// How long a notice that expires stays.
    static let noticeDuration: TimeInterval = 10

    /// The footer after an action: nil clears it; one that expires leaves
    /// on its own after `noticeDuration`.
    func show(_ notice: AllNotesNotice?) {
        noticeTimer?.invalidate()
        noticeTimer = nil
        self.notice = notice
        guard let notice, notice.expires else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval: Self.noticeDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.notice = nil }
        }
    }

    /// Clear, Esc, or the scope switching: nothing checked, nothing said.
    func clearSelection() {
        selected.clear()
        show(nil)
    }
}

/// The sidebar (search with the count inside, Active / Archived, the list
/// with a checkbox per row and drag-to-reorder, the license card while
/// read-only, and the selection bar docked at its foot while anything is
/// checked) and the preview pane: the previewed note's state, its actions
/// as chips, the pill, and the note drawn as its own paper on the
/// window's ground (design/products/opennotes.md, "All Notes").
struct AllNotesView: View {
    let model: AppModel
    let openNote: (NoteID) -> Void
    let export: (NoteID, ExportFormat) -> Void
    /// Export… on the checked set: one file per note into a folder.
    let exportMany: ([NoteID], ExportFormat) -> Void
    /// The search, the Active / Archived choice, the selection and the
    /// checked set: owned by the controller, so a window made anew (the
    /// screen-sharing setting turning off) shows the same list.
    @Bindable var session: AllNotesSession
    @State private var hovered: NoteID?
    @State private var showsColors = false
    @State private var showsFonts = false
    @FocusState private var searchFocused: Bool
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.colorScheme) private var colorScheme

    /// The sidebar's width in the harness and its ideal width in the window.
    static let sidebarWidth: CGFloat = 300
    /// The colour panel's owner while it picks for the checked set.
    static let colorPanelOwner = "allnotes:selection"

    /// `session` is the controller's, or a fresh one whose `query` is what
    /// the search field starts with (the harness's no-results stage);
    /// `hover` is the row the pointer rests on (the harness only).
    init(model: AppModel, openNote: @escaping (NoteID) -> Void, export: @escaping (NoteID, ExportFormat) -> Void, exportMany: @escaping ([NoteID], ExportFormat) -> Void = { _, _ in }, session: AllNotesSession = AllNotesSession(), hover: NoteID? = nil) {
        self.model = model
        self.openNote = openNote
        self.export = export
        self.exportMany = exportMany
        self.session = session
        _hovered = State(initialValue: hover)
    }

    private var query: String { session.query }
    private var showsArchived: Bool { session.showsArchived }
    private var selection: NoteID? { session.selection }

    private var notes: [Note] {
        model.search(query, archived: showsArchived)
    }

    private var visibleIDs: [NoteID] { notes.map(\.id) }

    /// The checked notes on view, in list order.
    private var checked: [NoteID] { session.selected.ordered(in: visibleIDs) }

    /// Anything checked: the selection bar is up at the foot of the list.
    /// The pane never changes with it — the previewed note keeps its own
    /// actions, since the checked rows are on the left.
    private var selecting: Bool { !checked.isEmpty }

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
            // What the last bulk action left to say: the notes it skipped
            // and why, or the files now in the Trash.
            if let notice = session.notice {
                Divider()
                noticeRow(notice)
                    .padding(.horizontal, Brand.Space.s16)
                    .padding(.vertical, Brand.Space.s8)
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
        .background(shortcuts)
        // A checked note that left the list (a narrower search, a file
        // gone, archived) leaves the set: what is checked is on view.
        .onChange(of: visibleIDs) { _, ids in session.selected.keep(ids) }
        // The colour panel picking for the checked set closes with it.
        .onChange(of: selecting) { _, selecting in
            if !selecting { NoteColorPanel.shared.dismiss(for: Self.colorPanelOwner) }
        }
        .sheet(item: Binding(get: { session.pendingDelete.map(DeleteRequest.init) }, set: { session.pendingDelete = $0?.ids })) { request in
            DeleteConfirmation(
                titles: request.ids.compactMap { model.note($0)?.title },
                onCancel: { session.pendingDelete = nil },
                onConfirm: {
                    session.pendingDelete = nil
                    trash(request.ids)
                }
            )
        }
    }

    // MARK: - Keyboard

    /// ⌘A checks every row on view, Space toggles the previewed row's
    /// box, Esc clears the checked set (⌘⇧A is the bulk Archive chip's
    /// own). Nothing while the search field has the keyboard: there ⌘A
    /// selects the text and Space types.
    @ViewBuilder private var shortcuts: some View {
        if !searchFocused, !previewRendering {
            Group {
                if !notes.isEmpty {
                    Button("Select all") { session.selected.checkAll(visibleIDs) }
                        .keyboardShortcut("a", modifiers: .command)
                }
                if let focused = selection ?? notes.first?.id {
                    Button("Check") { session.selected.toggle(focused) }
                        .keyboardShortcut(.space, modifiers: [])
                }
                if selecting {
                    Button("Clear selection") { session.clearSelection() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Sidebar

    /// The head, the license card, the list, and — while anything is
    /// checked — the selection bar docked at the foot, sliding up with
    /// the first check and down with the last uncheck (the header count
    /// fades in at the top at the same time).
    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: Brand.Space.s8) {
                searchField
                HStack(spacing: Brand.Space.s4) {
                    scopeChip("Active", archived: false)
                    scopeChip("Archived", archived: true)
                    Spacer(minLength: 0)
                }
                if selecting {
                    selectionHeader
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(Brand.Space.s12)
            // Why the notes are read-only, in LICENSING.md's words with the
            // way out, above the list it gates. Asked on every body.
            if model.license.restriction() != nil {
                LicenseCard(license: model.license, footnote: AllNotesText.readOnlyFootnote)
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
            if selecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The bar slides in from under the column's foot, not over the
        // window's rows below the split.
        .clipped()
        .animation(.easeOut(duration: Brand.Motion.standard), value: selecting)
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
                    .focused($searchFocused)
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

    /// Active / Archived: the chosen one carries the accent. Switching
    /// clears the checked set: Archive and Restore are not the same bar.
    private func scopeChip(_ title: String, archived: Bool) -> some View {
        let selected = showsArchived == archived
        return Button {
            guard session.showsArchived != archived else { return }
            session.showsArchived = archived
            session.selection = nil
            session.clearSelection()
        } label: {
            Text(title)
        }
        .buttonStyle(ChipButtonStyle(tone: selected ? .selected : .quiet))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Once one row is checked: the all / none box and the count.
    private var selectionHeader: some View {
        let coverage = session.selected.coverage(of: visibleIDs)
        return HStack(spacing: 10) {
            checkbox(state: coverage == .all ? .on : coverage == .some ? .mixed : .off, label: coverage == .all ? "Select none" : "Select all") {
                if coverage == .all { session.selected.clear() } else { session.selected.checkAll(visibleIDs) }
            }
            Text(AllNotesText.selected(checked.count, of: notes.count))
                .font(Brand.body(12, weight: 600))
                .monospacedDigit()
                .foregroundStyle(Brand.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(height: 22)
        .accessibilityElement(children: .contain)
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

    /// The checkbox, the color as the deck's pill dash, the title with the
    /// pin, the age, the title and the first line in the note's own font.
    /// A note iCloud has not downloaded is only its file name: greyed,
    /// "Downloading…" where the preview line goes, a cloud glyph in place
    /// of the age. The box shows on hover and while anything is checked.
    private func row(_ note: Note) -> some View {
        let look = model.appearance(of: note)
        let downloading = note.isDownloading && !note.bodyIsLoaded
        let isChecked = session.selected.contains(note.id)
        let boxShown = isChecked || selecting || hovered == note.id
        return HStack(alignment: .center, spacing: 10) {
            checkbox(state: isChecked ? .on : .off, label: isChecked ? "Uncheck \(note.title)" : "Check \(note.title)") {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    session.selected.extend(to: note.id, in: visibleIDs)
                } else {
                    session.selected.toggle(note.id)
                }
            }
            .opacity(boxShown ? 1 : 0)
            .animation(.easeOut(duration: Brand.Motion.fast), value: boxShown)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AllNotesText.rowLabel(note, checked: isChecked))
    }

    /// A round box in the accent: an AppKit control in the window, so a
    /// click on it never moves the list's selection (the table leaves a
    /// control's click to the control); drawn flat in the harness.
    private func checkbox(state: RoundCheckbox.State, label: String, action: @escaping () -> Void) -> some View {
        Group {
            if previewRendering {
                RoundCheckboxShape(state: state)
            } else {
                RoundCheckbox(state: state, action: action)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(label)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }

    // MARK: - Preview

    /// The previewed note's caption, actions and paper. The checked set
    /// never shows here: its bar is at the foot of the list.
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
            }
            if let note = selected {
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
    /// icons with help tags when it is not. Delete… (archived notes, in
    /// red) is last and absent while read-only.
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
            exportMenu(compact: compact, enabled: note.bodyIsLoaded) { export(note.id, $0) }
            chip("Reveal in Finder", symbol: "folder", compact: compact) { model.revealInFinder(note.id) }
            if note.archived, !model.readOnly {
                chip("Delete…", symbol: "trash", compact: compact, tone: .danger) { session.pendingDelete = [note.id] }
            }
        }
    }

    // MARK: - Selection bar

    /// Docked at the foot of the list, over a hairline, shaped like the
    /// pane's head: a small caption with the count over the checked set's
    /// actions as glyph-and-word chips, which wrap into a second row when
    /// the column is narrow (`AllNotesBulkAction.bar` says which: Archive
    /// with the accent — Restore under Archived — Pin / Unpin, Colour and
    /// Font for active notes, Export… and Reveal for any, Delete… in red
    /// under Archived, and Clear last). Each acts on the checked notes in
    /// list order; the store's refusals go to the footer. Read-only keeps
    /// only Export…, Reveal and Clear.
    private var selectionBar: some View {
        let ids = checked
        let allPinned = ids.allSatisfy { model.note($0)?.pinned == true }
        return VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: Brand.Space.s8) {
                HStack(spacing: Brand.Space.s8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.accentText)
                        .accessibilityHidden(true)
                    Text(AllNotesText.selectedCaption(ids.count))
                        .font(Brand.body(11, weight: 600))
                        .tracking(0.8)
                        .monospacedDigit()
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }
                .padding(.leading, 2)
                FlowLayout(spacing: 6) {
                    ForEach(AllNotesBulkAction.bar(archived: showsArchived, readOnly: model.readOnly, allPinned: allPinned)) { action in
                        bulkChip(action, ids: ids)
                    }
                }
            }
            // The list's rows are inset 8 pt; the chips' words then start
            // where the rows' checkboxes do.
            .padding(.horizontal, Brand.Space.s8)
            .padding(.vertical, Brand.Space.s12)
        }
        .background(Brand.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    @ViewBuilder private func bulkChip(_ action: AllNotesBulkAction, ids: [NoteID]) -> some View {
        switch action {
        case .restore:
            Button("Restore") { perform(model.unarchive(ids)) }
                .buttonStyle(ChipButtonStyle(tone: .primary))
        case .archive:
            Button("Archive") { perform(model.archive(ids)) }
                .buttonStyle(ChipButtonStyle(tone: .primary))
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Archive the checked notes (⌘⇧A)")
        case .pin:
            chip(action.title, symbol: "pin", compact: false) { perform(model.setPinned(true, for: ids)) }
        case .unpin:
            chip(action.title, symbol: "pin.slash", compact: false) { perform(model.setPinned(false, for: ids)) }
        case .colour:
            colorChip(compact: false)
        case .font:
            fontChip(compact: false)
        case .export:
            exportMenu(compact: false, enabled: true) { exportMany(ids, $0) }
        case .reveal:
            chip(action.title, symbol: "folder", compact: false) { model.revealInFinder(ids) }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
        case .delete:
            chip(action.title, symbol: "trash", compact: false, tone: .danger) { session.pendingDelete = ids }
        case .clear:
            chip(action.title, symbol: "xmark.circle", compact: false) { session.clearSelection() }
                .help("Clear the selection (Esc)")
        }
    }

    /// A bulk write's outcome to the footer: the skipped notes and why,
    /// or nothing when every note went through.
    private func perform(_ outcome: AppModel.BulkOutcome) {
        session.show(AllNotesNotice.refusals(in: outcome))
    }

    /// Delete… confirmed: the files to the Trash, the footer saying where
    /// they went — or which ones stayed and why.
    private func trash(_ ids: [NoteID]) {
        let outcome = model.trash(ids)
        if let skipped = AllNotesNotice.refusals(in: outcome) {
            session.show(skipped)
        } else {
            session.show(.trashed(count: outcome.done.count, urls: outcome.trashed))
        }
    }

    /// The colour the checked notes share, or none.
    private var commonColor: NoteColor? {
        let colors = Set(checked.compactMap { model.note($0)?.color })
        return colors.count == 1 ? colors.first : nil
    }

    /// The swatch grid and Custom… over the checked set; the swatch shows
    /// the shared colour, a palette glyph when they differ.
    private func colorChip(compact: Bool) -> some View {
        Button { showsColors.toggle() } label: {
            HStack(spacing: 5) {
                if let color = commonColor {
                    Circle()
                        .fill(NoteAppearance(color: color).swatch)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11, weight: .semibold))
                }
                if !compact { Text("Colour") }
            }
        }
        .buttonStyle(ChipButtonStyle(tone: .quiet))
        .help("Colour for the checked notes")
        .accessibilityLabel("Colour")
        .popover(isPresented: $showsColors, arrowEdge: .top) {
            ColorChooser(selected: commonColor, onPick: { color in
                perform(model.setColor(color, for: checked))
            }, onCustom: {
                showsColors = false
                // Each pick is a write to every checked note: the model asks
                // the license at every one, and the set is read at the pick.
                NoteColorPanel.shared.present(for: Self.colorPanelOwner, current: commonColor ?? .coral) { color in
                    perform(model.setColor(color, for: checked))
                }
            })
        }
    }

    /// The typeface the checked notes share (nil for the default), or none.
    private var commonTypeface: NoteTypeface?? {
        let faces = Set(checked.compactMap { model.note($0).map { $0.typeface } })
        return faces.count == 1 ? faces.first : nil
    }

    private func fontChip(compact: Bool) -> some View {
        let look = checked.first.flatMap { model.note($0) }.map { model.appearance(of: $0) }
        return Button { showsFonts.toggle() } label: {
            HStack(spacing: 5) {
                Text("Aa")
                    .font(Font((look?.nsFont(size: 11, weight: 600)) ?? Brand.noteFont(.sans, size: 11, weight: 600)))
                if !compact { Text("Font") }
            }
        }
        .buttonStyle(ChipButtonStyle(tone: .quiet))
        .help("Font for the checked notes")
        .accessibilityLabel("Font")
        .popover(isPresented: $showsFonts, arrowEdge: .top) {
            FontChooser(
                selection: commonTypeface ?? nil,
                size: Int(look?.size ?? CGFloat(model.preferences.size)),
                ownSize: checked.allSatisfy { model.note($0)?.fontSize != nil },
                offersDefault: true,
                onPick: { perform(model.setTypeface($0, for: checked)) },
                onSize: { perform(model.setFontSize($0, for: checked)) }
            )
        }
    }

    /// Export… as a menu of the two formats; a flat chip in the harness.
    @ViewBuilder private func exportMenu(compact: Bool, enabled: Bool, action: @escaping (ExportFormat) -> Void) -> some View {
        if previewRendering {
            chip("Export…", symbol: "square.and.arrow.up", compact: compact) {}
                .disabled(!enabled)
        } else {
            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.title) { action(format) }
                }
            } label: {
                chipLabel("Export…", symbol: "square.and.arrow.up", compact: compact)
            }
            .menuStyle(.button)
            .buttonStyle(ChipButtonStyle(tone: .quiet))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!enabled)
            .help("Export…")
            .accessibilityLabel("Export…")
        }
    }

    private func chip(_ title: String, symbol: String, compact: Bool, tone: ChipButtonStyle.Tone = .quiet, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, symbol: symbol, compact: compact)
        }
        .buttonStyle(ChipButtonStyle(tone: tone))
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

    // MARK: - Footer

    /// The bulk action's line: a refusal with its reasons (Dismiss), or
    /// the files moved to the Trash (Show in Finder).
    private func noticeRow(_ notice: AllNotesNotice) -> some View {
        HStack(spacing: Brand.Space.s8) {
            Image(systemName: notice.expires ? "trash" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(Brand.mono(11))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(notice.text)
            Spacer(minLength: 0)
            switch notice {
            case .trashed(_, let urls):
                if !urls.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                        .buttonStyle(.plain)
                        .font(Brand.body(11, weight: 600))
                        .foregroundStyle(Brand.accentText)
                }
            case .skipped:
                Button("Dismiss") { session.show(nil) }
                    .buttonStyle(.plain)
                    .font(Brand.body(11, weight: 600))
                    .foregroundStyle(Brand.accentText)
            }
        }
        .accessibilityElement(children: .contain)
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

/// The archived notes Delete… asks about (the sheet's item).
private struct DeleteRequest: Identifiable {
    let ids: [NoteID]
    var id: String { ids.map(\.rawValue).joined(separator: "\n") }
}

/// "Move 3 notes to the Trash?": the titles (five, then "and n more"),
/// that the Trash gives them back, Cancel and the red Move to Trash.
/// Return does nothing here — ⌘⌫ confirms, Esc cancels — so a Delete…
/// pressed in haste is never confirmed by the next keystroke.
struct DeleteConfirmation: View {
    let titles: [String]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            Text(AllNotesText.deleteTitle(titles))
                .font(Brand.display(18))
                .foregroundStyle(Brand.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            let lines = AllNotesText.deleteList(titles)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    // The last line is "and n more" when the list was cut.
                    let more = index == lines.count - 1 && lines.count < titles.count
                    Text(line)
                        .font(Brand.body(13))
                        .foregroundStyle(more ? Brand.textSecondary : Brand.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Brand.Space.s12)
            .padding(.vertical, Brand.Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            Text(AllNotesText.deleteDetail)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.Space.s8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onConfirm)
                    .buttonStyle(DangerButtonStyle())
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Move to the Trash (⌘⌫)")
            }
        }
        .padding(Brand.Space.s24)
        .frame(width: 400)
        .background(Brand.canvas)
        .accessibilityElement(children: .contain)
    }
}

/// The one destructive button: red, filled, never the default.
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(14, weight: 600))
            .foregroundStyle(Brand.accentOn)
            .padding(.horizontal, Brand.Space.s16)
            .frame(minHeight: 32)
            .background(Brand.dangerSolid, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
    }
}

/// A small action: the accent for the one primary action, a quiet surface
/// for the rest, the accent's tint for a chosen scope, red text for the
/// one destructive action. Press feedback is a small scale, disabled a
/// fade.
struct ChipButtonStyle: ButtonStyle {
    enum Tone { case primary, quiet, selected, danger }

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
        case .danger: Brand.dangerSolid
        }
    }

    private func background(pressed: Bool) -> Color {
        switch tone {
        case .primary: pressed ? Brand.accentSolid.opacity(0.85) : Brand.accentSolid
        case .quiet: pressed ? Brand.hover : Brand.surface
        case .selected: Brand.accentSubtle
        case .danger: pressed ? Brand.dangerSubtle : Brand.surface
        }
    }
}

/// The round checkbox as an AppKit button: an `NSControl` in a list row
/// takes its own click, so checking a note never moves the list's
/// selection (the previewed note). Drawn here, not by a cell: the SF
/// Symbol for the state (`RoundCheckboxGlyph`), the ring in the control
/// border, filled with the accent and a checkmark when on, a dash for a
/// mixed header.
struct RoundCheckbox: NSViewRepresentable {
    enum State: Equatable {
        case off, on, mixed

        /// The SF Symbol drawn for the state: a ring, a filled circle
        /// with a checkmark, a filled circle with a dash.
        var symbolName: String {
            switch self {
            case .off: "circle"
            case .on: "checkmark.circle.fill"
            case .mixed: "minus.circle.fill"
            }
        }
    }

    let state: State
    let action: () -> Void

    func makeNSView(context: Context) -> BoxButton {
        let button = BoxButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked)
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: BoxButton, context: Context) {
        context.coordinator.action = action
        if button.boxState != state {
            button.boxState = state
            button.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }

    final class BoxButton: NSButton {
        var boxState: State = .off

        override var intrinsicContentSize: NSSize { NSSize(width: RoundCheckboxGlyph.side, height: RoundCheckboxGlyph.side) }
        override var acceptsFirstResponder: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let image = RoundCheckboxGlyph.image(state: boxState, dark: dark)
            image.draw(in: RoundCheckboxGlyph.frame(of: image, in: bounds), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The same glyph for the harness (`ImageRenderer` draws no AppKit view):
/// the very image the button draws, at its own size on the control's,
/// so a render shows what the window shows.
struct RoundCheckboxShape: View {
    let state: RoundCheckbox.State
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let image = RoundCheckboxGlyph.image(state: state, dark: colorScheme == .dark)
        Image(nsImage: image)
            .resizable()
            .frame(width: image.size.width, height: image.size.height)
            .frame(width: RoundCheckboxGlyph.side, height: RoundCheckboxGlyph.side)
    }
}

/// The checkbox's picture: the state's SF Symbol, medium weight, coloured
/// by palette — the ring in the control border, a filled circle in the
/// accent with the mark in the accent's ink. 0.1.2 drew the mark as its
/// own `NSBezierPath` with y up, but `NSButton` is flipped, so the tick's
/// vertex landed at the top: an up-chevron. A symbol has no orientation
/// to get wrong.
enum RoundCheckboxGlyph {
    /// The control's side in the row and the header.
    static let side: CGFloat = 16
    /// The symbol's point size: its circle spans about 15 pt, inside the
    /// control, in an image a little larger with the symbol's margins.
    static let pointSize: CGFloat = 15

    /// The image at its own size, centred on a control's bounds.
    static func frame(of image: NSImage, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
    }

    static func image(state: RoundCheckbox.State, dark: Bool) -> NSImage {
        let accent = NSColor(hex: dark ? 0xFFA48A : 0xA53A20)
        let ring = NSColor(hex: 0x858585)
        let mark = NSColor(hex: dark ? 0x141414 : 0xFFFFFF)
        // Palette order for a `.fill` symbol: the mark, then the circle.
        let colors = state == .off ? [ring] : [mark, accent]
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium, scale: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        return image
    }
}

/// Views laid out left to right, wrapping to the next row when the
/// width runs out — the selection bar's chips in a narrow column. Each
/// row's items are centred on its height.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * rowSpacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// The subviews at their ideal sizes, cut into rows no wider than
    /// `width`; an item wider than the row alone still gets its row.
    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let next = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
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

    /// The sidebar's head once one row is checked, beside the all / none
    /// box.
    static func selected(_ count: Int, of visible: Int) -> String {
        "\(count) of \(visible) selected"
    }

    /// The caption over the selection bar's chips: what they act on.
    static func selectedCaption(_ count: Int) -> String {
        "\(count) SELECTED"
    }

    /// The footer after a bulk action the store refused for some notes:
    /// how many of how many, and each distinct reason.
    static func skipped(_ count: Int, of attempted: Int, reasons: [String]) -> String {
        let head = "\(count) of \(attempted) skipped"
        return reasons.isEmpty ? head : "\(head): \(reasons.joined(separator: " · "))"
    }

    /// The footer after Delete…: what went to the Trash.
    static func trashed(_ count: Int) -> String {
        "Moved \(count == 1 ? "1 note" : "\(count) notes") to the Trash"
    }

    /// The sheet's question.
    static func deleteTitle(_ titles: [String]) -> String {
        titles.count == 1 ? "Move “\(titles[0])” to the Trash?" : "Move \(titles.count) notes to the Trash?"
    }

    /// The sheet's list: the first five titles, then how many more.
    static func deleteList(_ titles: [String], limit: Int = 5) -> [String] {
        guard titles.count > limit else { return titles }
        return Array(titles.prefix(limit)) + ["and \(titles.count - limit) more"]
    }

    static let deleteDetail = "The files leave the notes folder for the Trash, where Finder can put them back. OpenNotes never deletes a file for good."

    /// Under the license card in the sidebar: what waits, what works.
    static let readOnlyFootnote = "Pin, Archive, Restore, Colour, Font, reordering and Delete wait for a license; Export and Reveal in Finder work now."

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

    /// The row for VoiceOver: the title, pinned, the age, checked.
    static func rowLabel(_ note: Note, checked: Bool = false, now: Date = Date()) -> String {
        let state = note.isDownloading && !note.bodyIsLoaded ? "downloading" : Age.text(note.modified, now: now)
        return [note.title, note.pinned ? "pinned" : nil, state, checked ? "checked" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}
