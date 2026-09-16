import AppKit
import OpenNotesCore
import SwiftUI
import UniformTypeIdentifiers

final class AllNotesWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let openNote: (NoteID) -> Void
    private var window: NSWindow?

    init(model: AppModel, openNote: @escaping (NoteID) -> Void) {
        self.model = model
        self.openNote = openNote
    }

    func show() {
        if window == nil {
            let root = AllNotesView(model: model, openNote: openNote, export: { [weak self] id, format in self?.export(id, as: format) })
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 520)),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "All Notes"
            window.minSize = NSSize(width: 560, height: 360)
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.setFrameAutosaveName("AllNotes")
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
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

/// Search, Active / Archived, the list with drag-to-reorder, the preview
/// pane with its actions (design/products/opennotes.md, "All Notes").
struct AllNotesView: View {
    let model: AppModel
    let openNote: (NoteID) -> Void
    let export: (NoteID, ExportFormat) -> Void
    @State private var query = ""
    @State private var showsArchived = false
    @State private var selection: NoteID?
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.colorScheme) private var colorScheme

    private var notes: [Note] {
        model.search(query, archived: showsArchived)
    }

    private var selected: Note? {
        (selection.flatMap { model.note($0) } ?? notes.first).flatMap { model.body(of: $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The trial's remaining time, or why the notes are read-only,
            // as a pill over the toolbar (official builds; nothing while
            // licensed), and while read-only the license card in
            // LICENSING.md's words with the way out. Asked on every body.
            if model.license.badge() != nil || model.license.restriction() != nil {
                VStack(spacing: Brand.Space.s8) {
                    LicensePillHeader(license: model.license)
                    LicenseCard(license: model.license)
                }
                .padding(.horizontal, Brand.Space.s12)
                .padding(.top, Brand.Space.s12)
            }
            Group {
                if previewRendering {
                    // `ImageRenderer` draws no split view: a fixed split.
                    HStack(spacing: 0) {
                        list.frame(width: 320)
                        Divider()
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    HSplitView {
                        list.frame(minWidth: 280, idealWidth: 320)
                        preview.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            // An update asking for something (official builds): one line
            // under the split, nothing otherwise.
            if model.updates.hint() != nil {
                Divider()
                UpdateHintRow(updates: model.updates)
                    .padding(.horizontal, Brand.Space.s12)
                    .padding(.vertical, Brand.Space.s8)
            }
        }
        .background(Brand.canvas)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: Brand.Space.s8) {
                if previewRendering {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Brand.textSecondary)
                        Text(query.isEmpty ? "Search" : query).foregroundStyle(query.isEmpty ? Brand.textSecondary : Brand.textPrimary)
                        Spacer()
                    }
                    .font(Brand.body(13))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Brand.surface, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search notes")
                }
                if previewRendering {
                    HStack(spacing: 2) {
                        segment("Active", selected: !showsArchived)
                        segment("Archived", selected: showsArchived)
                    }
                    .padding(2)
                    .background(Brand.surface, in: RoundedRectangle(cornerRadius: 7))
                } else {
                    Picker("", selection: $showsArchived) {
                        Text("Active").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            .padding(Brand.Space.s12)
            Divider()
            if notes.isEmpty {
                VStack(spacing: Brand.Space.s8) {
                    Spacer()
                    Text(query.isEmpty ? (showsArchived ? "Nothing archived." : "No notes yet.") : "No note matches “\(query)”.")
                        .font(Brand.body(13))
                        .foregroundStyle(Brand.textSecondary)
                    if query.isEmpty, !showsArchived {
                        Text("Press the hotkey anywhere, or click + on the deck.")
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if previewRendering {
                VStack(spacing: 0) {
                    ForEach(notes) { note in
                        row(note).padding(.horizontal, 8).padding(.vertical, 6)
                            .background(selected?.id == note.id ? Brand.accentSubtle : Color.clear)
                    }
                    Spacer()
                }
            } else {
                List(selection: $selection) {
                    ForEach(notes) { note in
                        row(note).tag(note.id)
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
                .listStyle(.inset)
                .accessibilityLabel(showsArchived ? "Archived notes" : "Active notes")
            }
        }
    }

    private func segment(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(Brand.body(12, weight: selected ? 600 : 400))
            .foregroundStyle(Brand.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(selected ? Brand.canvas : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func row(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: Brand.Space.s8) {
            RoundedRectangle(cornerRadius: 2).fill(model.appearance(of: note).tab).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Brand.textSecondary) }
                    Text(note.title).font(Brand.body(13, weight: 600)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                }
                Text(note.preview.isEmpty ? " " : note.preview).font(Brand.body(12)).foregroundStyle(Brand.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Age.text(note.modified)).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !note.archived { openNote(note.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.title), \(Age.text(note.modified))")
    }

    private var preview: some View {
        Group {
            if let note = selected {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Brand.Space.s8) {
                        if note.archived {
                            Button("Restore") { model.unarchive(note.id) }.disabled(model.readOnly)
                        } else {
                            Button("Open") { openNote(note.id) }.keyboardShortcut(.defaultAction)
                            Button(note.pinned ? "Unpin" : "Pin") { model.setPinned(!note.pinned, for: note.id) }.disabled(model.readOnly)
                            Button("Archive") { model.archive(note.id) }.disabled(model.readOnly)
                        }
                        Spacer()
                        if previewRendering {
                            Button("Export…") {}
                        } else {
                            Menu("Export…") {
                                ForEach(ExportFormat.allCases, id: \.self) { format in
                                    Button(format.title) { export(note.id, format) }
                                }
                            }
                            .fixedSize()
                        }
                        Button("Reveal in Finder") { model.revealInFinder(note.id) }
                    }
                    .padding(Brand.Space.s12)
                    Divider()
                    let look = model.appearance(of: note)
                    Group {
                        if previewRendering {
                            PreviewText(text: note.text, look: look, dark: colorScheme == .dark)
                                .padding(Brand.Space.s16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            ScrollView {
                                PreviewText(text: note.text, look: look, dark: colorScheme == .dark)
                                    .padding(Brand.Space.s16)
                            }
                        }
                    }
                    .background(look.paper)
                    Divider()
                    Text("\(note.id.fileName) · \(note.color.title)\(note.color.isCustom ? " \(note.color.rawValue)" : "") · \(look.fontTitle) \(Int(look.size)) pt · created \(note.created.formatted(date: .abbreviated, time: .shortened))" + (note.bodyIsLoaded ? "" : " · can’t read the file right now; shown in part") + (look.missingFamily.map { " · “\($0)” isn’t installed here" } ?? ""))
                        .font(Brand.mono(10))
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                        .padding(Brand.Space.s12)
                }
            } else {
                Text("Select a note")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
