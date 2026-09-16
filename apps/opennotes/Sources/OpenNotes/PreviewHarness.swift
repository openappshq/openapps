#if DEBUG
import AppKit
import OpenAppsLicensing
import OpenNotesCore
import ServiceManagement
import SwiftUI

/// Renders the deck (pill, fan, open, editing, read-only) on a drawn
/// desktop, All Notes (and read-only with the license card), the license
/// card, the setup guide and Settings to PNGs, in light and dark
/// appearance: `OpenNotes --preview <directory>`. Debug builds only.
///
/// Nothing real is touched: no status item, no hotkey, a throwaway
/// defaults suite and a temporary notes folder (both removed at the end),
/// a login item that registers only in memory, and no window: the views
/// are drawn with `ImageRenderer` (see `write`), so the editor and the
/// hotkey field draw their flat stand-ins under `previewRendering`.
@MainActor
final class PreviewHarness {
    nonisolated static let suiteDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("space.openapps.opennotes.preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    nonisolated static let suite = suiteDirectory.appendingPathComponent("defaults").path

    private let outputDirectory: URL
    private let defaults: UserDefaults
    private let folder: URL
    private let preferences: Preferences
    private let model: AppModel
    private let loginItem: LoginItem
    private let hotkeys = HotkeyCenter()
    /// The license the model reads: bound to an ended trial for the
    /// read-only stages, to nothing (always on) for the rest.
    private let license = LicenseStatus()
    private var restricted = false

    private final class MemoryFlags: FlagStore {
        var values: [String: Any] = [:]
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
        func set(_ value: Int, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func hasValue(forKey key: String) -> Bool { values[key] != nil }
    }

    /// Registers in memory only.
    private final class PreviewLoginItemService: LoginItemService {
        private(set) var status: SMAppService.Status = .enabled
        func register() throws { status = .enabled }
        func unregister() throws { status = .notRegistered }
        func openSystemSettings() { print("PREVIEW_OPEN_LOGIN_ITEMS") }
    }

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(at: Self.suiteDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: Self.suite)!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        preferences = Preferences(defaults: defaults)
        // The throwaway suite is a fresh install: Settings shows the
        // screen-sharing default as a first launch leaves it.
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: true)
        preferences.folder = folder
        loginItem = LoginItem(flags: MemoryFlags(), service: PreviewLoginItemService())
        model = AppModel(preferences: preferences, license: license, store: NoteStore(folder: folder), watcher: FolderWatcher())
        AppResources.registerFonts()
        if let icon = AppResources.appIcon() { NSApp.applicationIconImage = icon }
        license.openLicense = { print("PREVIEW_OPEN_LICENSE") }
        setRestricted(false)
    }

    /// An ended trial, as the controller would project it (the card, the
    /// pill, no access), or everything on.
    private func setRestricted(_ restricted: Bool) {
        self.restricted = restricted
        let state: LicenseState? = restricted ? .trialEnded : nil
        license.bind(
            access: { !restricted },
            state: { state },
            restriction: { state.flatMap { LicenseRestriction.card(for: $0) } },
            badge: { state.flatMap { LicenseBadge.label(for: $0, appName: Licensing.appName) } },
            canBuy: true
        )
    }

    /// Every surface in both appearances; true when every PNG was written.
    func run() async -> Bool {
        defer {
            defaults.removePersistentDomain(forName: Self.suite)
            defaults.removeSuite(named: Self.suite)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: Self.suiteDirectory)
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("PREVIEW_FAILED \(error)")
            return false
        }
        seedNotes()
        model.store.load(create: false)
        // A second, empty folder taken through the model's own launch
        // path: the welcome note is what `start()` plants there.
        let welcome = welcomeModel()
        defer { if let folder = welcome?.store.folder { try? FileManager.default.removeItem(at: folder) } }
        let three = seededModel(count: 3)
        let twelve = seededModel(count: 12)
        defer { for folder in [three, twelve].compactMap({ $0?.store.folder }) { try? FileManager.default.removeItem(at: folder) } }
        var failures = 0
        let notes = model.active
        let groceries = notes.first { $0.title == "Groceries" }?.id ?? notes[0].id
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let scheme: ColorScheme = appearance == .aqua ? .light : .dark
            let stages: [(String, DeckState, Bool, Bool)] = [
                ("pill", .pill, false, false),
                ("fan", .fan, false, false),
                ("open", .open(groceries, editing: false), false, false),
                ("editing", .open(groceries, editing: true), false, false),
                ("readonly", .open(groceries, editing: false), true, false),
                ("toast", .fan, false, true),
            ]
            for (name, state, readOnly, toast) in stages {
                setRestricted(readOnly)
                let stage = DeckStage(content: content(state: state, toast: toast), side: preferences.side, dark: scheme == .dark)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "deck-\(name)-\(suffix).png") { failures += 1 }
            }
            setRestricted(false)
            // Text held over the pill: the pill lit as the drop's target;
            // then over the `+` tab with the fan out.
            var dropPill = content(state: .pill, toast: false)
            dropPill.dropTarget = true
            if await !write(DeckStage(content: dropPill, side: preferences.side, dark: scheme == .dark), scheme: scheme, appearance: appearance, to: "deck-drop-target-\(suffix).png") { failures += 1 }
            var dropFan = content(state: .fan, toast: false)
            dropFan.dropTarget = true
            if await !write(DeckStage(content: dropFan, side: preferences.side, dark: scheme == .dark), scheme: scheme, appearance: appearance, to: "deck-drop-target-fan-\(suffix).png") { failures += 1 }
            // The same drag while read-only: refused, the license line
            // under the pill.
            setRestricted(true)
            var dropRefused = content(state: .pill, toast: false, notice: true)
            dropRefused.dropRefusal = model.readOnlyNotice
            if await !write(DeckStage(content: dropRefused, side: preferences.side, dark: scheme == .dark), scheme: scheme, appearance: appearance, to: "deck-drop-refused-\(suffix).png") { failures += 1 }
            setRestricted(false)
            // A tab lifted mid-drag: the third note pulled up past the
            // second, which has slid into the gap.
            var dragContent = content(state: .fan, toast: false)
            if notes.count > 2 {
                let slot = dragContent.layout.tabs[2].frame
                dragContent.staticDrag = DeckDrag(id: notes[2].id, centerY: dragContent.layout.panelFrame.height - slot.midY - 1.3 * dragContent.layout.tabStep)
            }
            let drag = DeckStage(content: dragContent, side: preferences.side, dark: scheme == .dark)
            if await !write(drag, scheme: scheme, appearance: appearance, to: "deck-drag-\(suffix).png") { failures += 1 }
            // The fan with three tabs (no fade), and with twelve: scrolled
            // to the top (a fade below), the middle (both), the bottom (a
            // fade above), each tab at its own tilt.
            if let three {
                let stage = DeckStage(content: content(state: .fan, toast: false, model: three), side: preferences.side, dark: scheme == .dark)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "deck-fan-3-\(suffix).png") { failures += 1 }
            }
            if let twelve {
                let top = content(state: .fan, toast: false, model: twelve)
                for (name, offset) in [("top", 0), ("middle", top.layout.maxScroll / 2), ("bottom", top.layout.maxScroll)] {
                    let stage = DeckStage(content: content(state: .fan, toast: false, model: twelve, scroll: offset), side: preferences.side, dark: scheme == .dark)
                    if await !write(stage, scheme: scheme, appearance: appearance, to: "deck-fan-12-\(name)-\(suffix).png") { failures += 1 }
                }
            }
            // The welcome note, as the first launch into an empty folder
            // leaves it: open, every marker styled.
            if let welcome {
                let stage = DeckStage(content: content(state: .open(WelcomeNote.id, editing: false), toast: false, model: welcome), side: preferences.side, dark: scheme == .dark)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "deck-welcome-\(suffix).png") { failures += 1 }
            }
            // The left edge, once.
            preferences.side = .left
            let left = DeckStage(content: content(state: .open(groceries, editing: true), toast: false), side: .left, dark: scheme == .dark)
            if await !write(left, scheme: scheme, appearance: appearance, to: "deck-left-\(suffix).png") { failures += 1 }
            preferences.side = .right
            let allNotes = AllNotesView(model: model, openNote: { _ in }, export: { _, _ in })
                .frame(width: 760, height: 520)
                .background(Brand.canvas)
            if await !write(allNotes, scheme: scheme, appearance: appearance, to: "allnotes-\(suffix).png") { failures += 1 }
            // All Notes read-only: the card above the list, the pill in the
            // toolbar, Pin / Archive disabled; then the card on its own.
            setRestricted(true)
            let allNotesReadOnly = AllNotesView(model: model, openNote: { _ in }, export: { _, _ in })
                .frame(width: 760, height: 560)
                .background(Brand.canvas)
            if await !write(allNotesReadOnly, scheme: scheme, appearance: appearance, to: "allnotes-readonly-\(suffix).png") { failures += 1 }
            let card = LicenseCard(license: license)
                .padding(Brand.Space.s24)
                .frame(width: 520)
                .background(Brand.canvas)
            if await !write(card, scheme: scheme, appearance: appearance, to: "license-card-\(suffix).png") { failures += 1 }
            // The setup guide, every step, with the trial line and the
            // pill the ended trial gives the welcome step.
            let guide = OnboardingModel(loginItem: loginItem, license: license, preferences: preferences, defaults: MemoryFlags())
            for step in GuideStep.allCases {
                let view = OnboardingView(model: guide)
                if await !write(view, scheme: scheme, appearance: appearance, to: "guide-\(step)-\(suffix).png") { failures += 1 }
                guide.advance()
            }
            setRestricted(false)
            let settings = SettingsView(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, diagnostics: { "" })
                .background(Brand.canvas)
            if await !write(settings, scheme: scheme, appearance: appearance, to: "settings-\(suffix).png") { failures += 1 }
        }
        print("PREVIEW_RENDERED \(outputDirectory.path)")
        return failures == 0
    }

    private func seedNotes() {
        let base = Date()
        let samples: [(String, NoteColor, NoteFace, Bool, Int, TimeInterval)] = [
            ("Groceries\n- [x] milk\n- [X] eggs\n- [x] butter\n- [ ] sourdough from **Bread Ahead**\n  - [ ] the `[ ] seeded` one\n- [ ] coffee beans\n- [ ] apples\n\nAsk about the _oat_ one.", .coral, .sans, true, 0, -3600),
            ("Standup 16 Sep\n- feed key rotation\n- reply re ⌘W focus\n- release notes: paste as plain text", .yellow, .sans, false, 1, -7200),
            ("# Snippets\n`brew upgrade --cask opennotes`\nsee https://openapps.space/opennotes/", .sky, .mono, false, 2, -86_400),
            ("Side project\nName ideas, none good yet.", .mint, .sans, false, 3, -3 * 86_400),
            ("Call mum\nSunday, after lunch.", .lilac, .sans, false, 4, -9 * 86_400),
        ]
        for (text, color, face, pinned, order, age) in samples {
            let id = NoteFileName.id(for: Note.title(of: text), created: base) { _ in false }
            let note = Note(id: id, text: text, color: color, face: face, pinned: pinned, order: order, created: base.addingTimeInterval(age - 86_400), modified: base.addingTimeInterval(age))
            let url = folder.appendingPathComponent(id.fileName)
            try? Data(FrontMatter.serialize(note).utf8).write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: note.modified], ofItemAtPath: url.path)
        }
        let archived = Note(id: NoteID("old-plan"), text: "Old plan\nDone and dusted.", color: .paper, archived: true, created: base.addingTimeInterval(-30 * 86_400))
        try? Data(FrontMatter.serialize(archived).utf8).write(to: folder.appendingPathComponent(archived.id.fileName))
    }

    /// A model started over an empty temporary folder, exactly as a first
    /// launch is: the throwaway suite has no earlier preferences, so the
    /// welcome note is planted. Nil when the folder could not be made.
    private func welcomeModel() -> AppModel? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-preview-welcome-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let model = AppModel(preferences: preferences, license: license, store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.start()
        guard model.note(WelcomeNote.id) != nil else {
            print("PREVIEW_WELCOME_MISSING")
            return nil
        }
        return model
    }

    /// A model over a temporary folder with this many notes, titles and
    /// colours varied so the fan reads as a stack of different papers.
    private func seededModel(count: Int) -> AppModel? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-preview-\(count)-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let titles = ["Groceries", "Standup 16 Sep", "Snippets", "Side project", "Call mum", "Reading list", "Dentist Thursday", "Gift ideas", "Q4 plan notes", "Packing", "Recipes to try", "Passwords to rotate"]
        let colors = NoteColor.allCases
        let base = Date()
        for index in 0..<count {
            let title = titles[index % titles.count]
            let id = NoteFileName.id(for: title, created: base) { candidate in FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate.fileName).path) }
            let note = Note(id: id, text: "\(title)\nA line or two of text.", color: colors[index % colors.count], face: .sans, pinned: index == 0, order: index, created: base.addingTimeInterval(-Double(index) * 3600), modified: base.addingTimeInterval(-Double(index) * 3600))
            try? Data(FrontMatter.serialize(note).utf8).write(to: folder.appendingPathComponent(id.fileName))
        }
        let store = NoteStore(folder: folder)
        store.load(create: false)
        let model = AppModel(preferences: preferences, license: license, store: store, watcher: FolderWatcher())
        return model
    }

    /// The stage's screen: a 900 × 700 desktop.
    static let stageSize = CGSize(width: 900, height: 700)

    private func content(state: DeckState, toast: Bool, notice: Bool = false, model: AppModel? = nil, scroll: CGFloat = 0) -> DeckContent {
        let model = model ?? self.model
        let notes = model.active
        let visible = CGRect(origin: .zero, size: Self.stageSize)
        let layout = DeckGeometry.layout(state: state, side: preferences.side, visibleFrame: visible, notes: notes.map(\.id), toast: toast, notice: notice, scroll: scroll)
        let open = state.openNote.flatMap { model.note($0) }
        let status: String
        if model.readOnly { status = model.readOnlyNotice } else if state.isEditing { status = "Editing…" } else { status = open.map { "Saved · \(Age.text($0.modified))" } ?? "" }
        let pending = toast ? ArchiveUndo.Pending(id: NoteID("x"), title: "Call mum", deadline: .distantFuture) : nil
        return DeckContent(layout: layout, state: state, side: preferences.side, notes: notes, openNote: open, readOnly: model.readOnly, readOnlyNotice: model.readOnlyNotice, statusLine: status, pendingUndo: pending, folderMissing: false, license: license)
    }

    /// Draws the view with `ImageRenderer`, no window: the shared Mac's
    /// display may be asleep and locked, where the window server composites
    /// nothing.
    private func write(_ view: some View, scheme: ColorScheme, appearance: NSAppearance.Name, to name: String) async -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.previewRendering, true))
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image else {
            print("PREVIEW_CAPTURE_FAILED \(name)")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: outputDirectory.appendingPathComponent(name))
            print("PREVIEW_WROTE \(name) \(image.width)x\(image.height)")
            return true
        } catch {
            print("PREVIEW_WRITE_FAILED \(name) \(error)")
            return false
        }
    }
}

/// A drawn desktop with a document window behind, the deck docked to the
/// edge: what the real deck looks like in place, over light and dark.
private struct DeckStage: View {
    let content: DeckContent
    let side: DeckSide
    let dark: Bool

    var body: some View {
        let size = PreviewHarness.stageSize
        let frame = content.layout.panelFrame
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: dark ? [Color(nsColor: NSColor(hex: 0x242B55)), Color(nsColor: NSColor(hex: 0x141414))] : [Color(nsColor: NSColor(hex: 0xC1C9FF)), Color(nsColor: NSColor(hex: 0xFFF1EC))],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // A window in front, full-screen wide, so the deck reads as above it.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.gray.opacity(0.5)).frame(width: 12, height: 12) }
                    Spacer()
                    Text("Keynote — Q4 plan").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(Brand.surface)
                Rectangle().fill(Brand.canvas)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.borderSubtle, lineWidth: 1))
            .padding(EdgeInsets(top: 40, leading: 60, bottom: 40, trailing: 60))
            DeckView(content: content)
                .offset(x: frame.minX, y: size.height - frame.maxY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}
#endif
