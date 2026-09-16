#if DEBUG
import AppKit
import OpenAppsLicensing
import OpenNotesCore
import ServiceManagement
import SwiftUI

/// Renders the deck (pill, fan, open, editing, read-only) on a drawn
/// desktop, All Notes (and read-only with the license card), the license
/// card, the setup guide, Settings, the paper sheet (every preset with its
/// ink), a custom-coloured note, three fonts (a serif family, a monospaced
/// family, a family that is not installed) and the two menus to PNGs, in
/// light and dark appearance: `OpenNotes --preview <directory>`. Debug
/// builds only.
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
            // Every preset paper with its ink, and the contrast each reads at.
            let papers = PaperSheet(dark: scheme == .dark).background(Brand.canvas)
            if await !write(papers, scheme: scheme, appearance: appearance, to: "papers-\(suffix).png") { failures += 1 }
            // A note in a picked colour: the derived dark paper and ink.
            if let custom = notes.first(where: { $0.color.isCustom })?.id {
                let stage = DeckStage(content: content(state: .open(custom, editing: true), toast: false), side: preferences.side, dark: scheme == .dark)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "custom-color-\(suffix).png") { failures += 1 }
            }
            // Three notes side by side: a serif family, a monospaced family
            // (its checkboxes on its own grid), and a family this Mac does
            // not have, shown in the default with the footer's hint.
            let fonts = FontsStage(notes: notes.filter { $0.typeface?.family != nil }, content: content(state: .fan, toast: false), dark: scheme == .dark)
            if await !write(fonts, scheme: scheme, appearance: appearance, to: "fonts-\(suffix).png") { failures += 1 }
            let fontChooser = FontChooser(selection: .family("Menlo"), size: 14, ownSize: true, offersDefault: true, onPick: { _ in })
                .background(Brand.canvas)
            if await !write(fontChooser, scheme: scheme, appearance: appearance, to: "font-chooser-\(suffix).png") { failures += 1 }
            let colorChooser = ColorChooser(selected: .custom(0x7BAF9E), onPick: { _ in }, onCustom: {})
                .background(Brand.canvas)
            if await !write(colorChooser, scheme: scheme, appearance: appearance, to: "color-chooser-\(suffix).png") { failures += 1 }
        }
        print("PREVIEW_RENDERED \(outputDirectory.path)")
        return failures == 0
    }

    private func seedNotes() {
        let base = Date()
        let samples: [(String, NoteColor, NoteTypeface?, Bool, Int, TimeInterval)] = [
            ("Groceries\n- [x] milk\n- [ ] eggs\n- [ ] sourdough from **Bread Ahead**\n- [ ] coffee beans\n\nAsk about the _oat_ one.", .coral, .face(.sans), true, 0, -3600),
            ("Standup 16 Sep\n- feed key rotation\n- reply re ⌘W focus\n- release notes: paste as plain text", .yellow, nil, false, 1, -7200),
            ("# Snippets\n`brew upgrade --cask opennotes`\nsee https://openapps.space/opennotes/", .sky, .face(.mono), false, 2, -86_400),
            ("Side project\nName ideas, none good yet.", .mint, nil, false, 3, -3 * 86_400),
            ("Call mum\nSunday, after lunch.", .lilac, nil, false, 4, -9 * 86_400),
            // A picked colour, and three families: installed serif and mono, and one that is not here.
            ("Garden\n- [ ] repot the **fig**\n- [x] order seeds\nWater the _basil_ daily.", .custom(0x7BAF9E), nil, false, 5, -12 * 86_400),
            ("Reading list\n**Piranesi**, _Susanna Clarke_\n- [ ] The Overstory\n- [x] Bewilderment", .sand, .family("Georgia"), false, 6, -14 * 86_400),
            ("Deploy\n- [x] `git tag v0.1.1`\n- [ ] make-appcast.sh\n- [ ] verify-release.sh", .slate, .family("Menlo"), false, 7, -15 * 86_400),
            ("Letter\nDear **Ada**, the font this was written in lives on the other Mac.", .butter, .family("Bodoni Ornamental Twelve"), false, 8, -16 * 86_400),
        ]
        for (text, color, typeface, pinned, order, age) in samples {
            let id = NoteFileName.id(for: Note.title(of: text), created: base) { _ in false }
            let note = Note(id: id, text: text, color: color, typeface: typeface, pinned: pinned, order: order, created: base.addingTimeInterval(age - 86_400), modified: base.addingTimeInterval(age))
            let url = folder.appendingPathComponent(id.fileName)
            try? Data(FrontMatter.serialize(note).utf8).write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: note.modified], ofItemAtPath: url.path)
        }
        let archived = Note(id: NoteID("old-plan"), text: "Old plan\nDone and dusted.", color: .paper, archived: true, created: base.addingTimeInterval(-30 * 86_400))
        try? Data(FrontMatter.serialize(archived).utf8).write(to: folder.appendingPathComponent(archived.id.fileName))
    }

    /// The stage's screen: a 900 × 700 desktop.
    static let stageSize = CGSize(width: 900, height: 700)

    private func content(state: DeckState, toast: Bool) -> DeckContent {
        let notes = model.active
        let visible = CGRect(origin: .zero, size: Self.stageSize)
        let layout = DeckGeometry.layout(state: state, side: preferences.side, visibleFrame: visible, notes: notes.map(\.id), toast: toast)
        let open = state.openNote.flatMap { model.note($0) }
        let status: String
        if model.readOnly { status = model.readOnlyNotice } else if state.isEditing { status = "Editing…" } else { status = open.map { "Saved · \(Age.text($0.modified))" } ?? "" }
        let pending = toast ? ArchiveUndo.Pending(id: NoteID("x"), title: "Call mum", deadline: .distantFuture) : nil
        return DeckContent(layout: layout, state: state, side: preferences.side, notes: notes, openNote: open, readOnly: model.readOnly, readOnlyNotice: model.readOnlyNotice, statusLine: status, pendingUndo: pending, folderMissing: false, license: license, defaults: NoteAppearance.Defaults(preferences))
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

/// Every preset as its fanned tab beside a small open note, with the
/// ink's contrast ratio: what the colour menu offers, in one appearance,
/// tab and paper judged side by side.
private struct PaperSheet: View {
    let dark: Bool

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(196), spacing: 12), count: 4)
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            Text("Papers · \(dark ? "Dark" : "Light") Mode").font(Brand.display(18)).foregroundStyle(Brand.textPrimary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    let look = NoteAppearance(color: color)
                    HStack(spacing: 6) {
                        // The tab, as the fan draws it.
                        ZStack(alignment: .top) {
                            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                                .fill(look.tab)
                            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                            Text(color.title)
                                .font(Brand.body(11, weight: 600))
                                .foregroundStyle(look.tabInk)
                                .fixedSize()
                                .rotationEffect(.degrees(90))
                                .frame(width: 32, height: 90)
                                .padding(.top, 8)
                        }
                        .frame(width: 40, height: 112)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(color.title).font(Font(look.nsFont(size: 15, weight: 600))).foregroundStyle(look.ink)
                            Text("Milk, eggs, bread").font(Font(look.nsFont(size: 12))).foregroundStyle(look.ink)
                            Text("Saved · 2 min ago").font(Brand.mono(9)).foregroundStyle(look.inkSecondary)
                            Spacer(minLength: 0)
                            HStack {
                                Text(NoteColor.hex(color.face(dark: dark))).font(Brand.mono(9)).foregroundStyle(look.inkSecondary)
                                Spacer()
                                Text(String(format: "%.1f:1", NotePaper.contrast(color.ink(dark: dark), color.face(dark: dark)))).font(Brand.mono(9)).foregroundStyle(look.inkSecondary)
                            }
                        }
                        .padding(10)
                        .frame(width: 150, height: 112, alignment: .topLeading)
                        .background(look.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
                    }
                }
            }
        }
        .padding(Brand.Space.s24)
    }
}

/// Three open notes side by side, each in its own family.
private struct FontsStage: View {
    let notes: [Note]
    let content: DeckContent
    let dark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Space.s16) {
            ForEach(notes) { note in
                NoteCard(note: note, content: content)
                    .frame(width: DeckMetrics().noteWidth, height: DeckMetrics().noteHeight)
            }
        }
        .padding(Brand.Space.s24)
        .background(dark ? Color(nsColor: NSColor(hex: 0x242B55)) : Color(nsColor: NSColor(hex: 0xC1C9FF)))
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
