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

    /// The temporary folder passes for iCloud's, so the footer's line and
    /// a placeholder note render; nothing is asked of iCloud.
    private final class PreviewUbiquity: Ubiquity {
        func isUbiquitous(_ url: URL) -> Bool { true }
        func startDownloading(_ url: URL) throws {}
        func unresolvedConflictVersions(of url: URL) -> [any UbiquityConflictVersion] { [] }
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
        model = AppModel(preferences: preferences, license: license, store: NoteStore(folder: folder, ubiquity: PreviewUbiquity()), watcher: FolderWatcher())
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
        // The placeholder: a note iCloud has not downloaded, opened.
        let readingList = NoteID("reading-list")
        _ = model.body(of: readingList)
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
                ("downloading", .open(readingList, editing: false), false, false),
            ]
            for (name, state, readOnly, toast) in stages {
                setRestricted(readOnly)
                let stage = DeckStage(content: content(state: state, toast: toast), side: preferences.side, dark: scheme == .dark)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "deck-\(name)-\(suffix).png") { failures += 1 }
            }
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
            // Automation: a note with `=` lines and their answers; a note
            // with links and the chip over one; the note-shaped refusal a
            // read-only `opennotes://new` shows beside the deck.
            let automation = sampleModel(Self.automationSamples)
            let automationNotes = automation.model.active
            let trip = automationNotes.first { $0.title == "Trip budget" }?.id ?? automationNotes[0].id
            let arithmetic = DeckStage(content: content(state: .open(trip, editing: true), toast: false, model: automation.model), side: preferences.side, dark: scheme == .dark)
            if await !write(arithmetic, scheme: scheme, appearance: appearance, to: "deck-arithmetic-\(suffix).png") { failures += 1 }
            let links = automationNotes.first { $0.title == "Links" }?.id ?? automationNotes[0].id
            var linksStage = DeckStage(content: content(state: .open(links, editing: false), toast: false, model: automation.model), side: preferences.side, dark: scheme == .dark)
            linksStage.chip = (label: "openapps.space", line: 2)
            if await !write(linksStage, scheme: scheme, appearance: appearance, to: "deck-links-\(suffix).png") { failures += 1 }
            setRestricted(true)
            var refusalStage = DeckStage(content: content(state: .pill, toast: false), side: preferences.side, dark: scheme == .dark)
            refusalStage.refusal = RefusalCard(notice: model.readOnlyNotice, color: model.colorForNewNote, license: license)
            if await !write(refusalStage, scheme: scheme, appearance: appearance, to: "refusal-\(suffix).png") { failures += 1 }
            setRestricted(false)
            try? FileManager.default.removeItem(at: automation.folder)
            // The left edge, once.
            preferences.side = .left
            let left = DeckStage(content: content(state: .open(groceries, editing: true), toast: false), side: .left, dark: scheme == .dark)
            if await !write(left, scheme: scheme, appearance: appearance, to: "deck-left-\(suffix).png") { failures += 1 }
            preferences.side = .right
            // All Notes over the deck's notes; then over its own folders:
            // none, one, ten with every color and both faces, ten with a
            // search that finds nothing; then read-only, the card above the
            // list, the pill beside the actions, Pin / Archive disabled;
            // then the card on its own.
            let allNotes = AllNotesView(model: model, openNote: { _ in }, export: { _, _ in })
                .frame(width: 800, height: 540)
                .background(Brand.canvas)
            if await !write(allNotes, scheme: scheme, appearance: appearance, to: "allnotes-\(suffix).png") { failures += 1 }
            for (name, count, query) in [("empty", 0, ""), ("one", 1, ""), ("ten", 10, ""), ("nomatch", 10, "zebra")] {
                let stage = allNotesModel(notes: count)
                let view = AllNotesView(model: stage.model, openNote: { _ in }, export: { _, _ in }, query: query)
                    .frame(width: 800, height: 540)
                    .background(Brand.canvas)
                if await !write(view, scheme: scheme, appearance: appearance, to: "allnotes-\(name)-\(suffix).png") { failures += 1 }
                try? FileManager.default.removeItem(at: stage.folder)
            }
            setRestricted(true)
            let allNotesReadOnly = AllNotesView(model: model, openNote: { _ in }, export: { _, _ in })
                .frame(width: 800, height: 600)
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
            // Over the ten samples: a note in a picked colour (the derived
            // dark paper and ink), open and editing; then three notes side
            // by side: a serif family, a monospaced family (its checkboxes
            // on its own grid), and a family this Mac does not have, shown
            // in the default with the footer's hint.
            let ten = allNotesModel(notes: 10)
            if let custom = ten.model.active.first(where: { $0.color.isCustom })?.id {
                let stage = DeckStage(content: content(state: .open(custom, editing: true), toast: false, model: ten.model), side: preferences.side, dark: scheme == .dark)
                if await !write(stage, scheme: scheme, appearance: appearance, to: "custom-color-\(suffix).png") { failures += 1 }
            }
            let fonts = FontsStage(notes: ten.model.active.filter { $0.typeface?.family != nil }, content: content(state: .fan, toast: false, model: ten.model), dark: scheme == .dark)
            if await !write(fonts, scheme: scheme, appearance: appearance, to: "fonts-\(suffix).png") { failures += 1 }
            try? FileManager.default.removeItem(at: ten.folder)
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

    private typealias Sample = (text: String, color: NoteColor, typeface: NoteTypeface?, pinned: Bool, order: Int, age: TimeInterval)

    /// The deck's five notes, then five more for All Notes' ten: a picked
    /// colour, three families (an installed serif and mono, and one this
    /// Mac does not have), a second pinned one, a long one. Every note
    /// without a typeface follows the default.
    private static let samples: [Sample] = [
        ("Groceries\n- [x] milk\n- [ ] eggs\n- [ ] sourdough from **Bread Ahead**\n- [ ] coffee beans\n\nAsk about the _oat_ one.", .coral, .face(.sans), true, 0, -3600),
        ("Standup 16 Sep\n- feed key rotation\n- reply re ⌘W focus\n- release notes: paste as plain text", .yellow, nil, false, 1, -7200),
        ("# Snippets\n`brew upgrade --cask opennotes`\nsee https://openapps.space/opennotes/", .sky, .face(.mono), false, 2, -86_400),
        ("Side project\nName ideas, none good yet.", .mint, nil, false, 3, -3 * 86_400),
        ("Call mum\nSunday, after lunch.", .lilac, nil, false, 4, -9 * 86_400),
        ("Garden\n- [ ] repot the **fig**\n- [x] order seeds\nWater the _basil_ daily.", .custom(0x7BAF9E), nil, false, 5, -12 * 86_400),
        ("Reading list\n**Piranesi**, _Susanna Clarke_\n- [ ] The Overstory\n- [x] Bewilderment", .sand, .family("Georgia"), true, 6, -20 * 60),
        ("Deploy\n- [x] `git tag v0.1.1`\n- [ ] make-appcast.sh\n- [ ] verify-release.sh", .slate, .family("Menlo"), false, 7, -15 * 86_400),
        ("Letter\nDear **Ada**, the font this was written in lives on the other Mac.", .butter, .family("Bodoni Ornamental Twelve"), false, 8, -16 * 86_400),
        ("Ideas for the talk\nStart with the folder, not the app. Show the file in Finder first, then the deck, then the same note in Obsidian. The point is that nothing is locked in: the notes were always theirs.\n\n## Demo order\n1. hotkey\n2. edge\n3. All Notes\n4. iCloud Drive", .paper, nil, false, 9, -2 * 86_400),
    ]

    /// Two notes for the automation stages, over their own folder: `=`
    /// lines with their answers, and every kind of link.
    private static let automationSamples: [Sample] = [
        ("Trip budget\nFlights $420\nHotel 3 * $95 =\nFood $18 * 4 = $72\nsum =\n\nsplit: $777 / 2 =\n1,250 * 8% =", .yellow, nil, false, 0, -2 * 86_400),
        ("Links\ndocs: https://openapps.space/opennotes/\nmail sam mailto:sam@example.com\nnotes: ~/Documents/OpenNotes/groceries.md\nsee www.example.org/page", .sky, nil, false, 1, -4 * 86_400),
    ]

    private func seedNotes() {
        let base = Date()
        Self.write(Array(Self.samples.prefix(5)), into: folder, base: base)
        let archived = Note(id: NoteID("old-plan"), text: "Old plan\nDone and dusted.", color: .paper, archived: true, created: base.addingTimeInterval(-30 * 86_400))
        try? Data(FrontMatter.serialize(archived).utf8).write(to: folder.appendingPathComponent(archived.id.fileName))
        // A note another Mac wrote that iCloud has not downloaded here:
        // the placeholder, as iCloud leaves it (a property list).
        let placeholder = ICloudDrive.placeholderName(for: NoteID("reading-list"))
        try? Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>NSURLNameKey</key><string>reading-list.md</string></dict></plist>".utf8).write(to: folder.appendingPathComponent(placeholder))
    }

    private static func write(_ samples: [Sample], into folder: URL, base: Date) {
        for sample in samples {
            let id = NoteFileName.id(for: Note.title(of: sample.text), created: base) { _ in false }
            let note = Note(id: id, text: sample.text, color: sample.color, typeface: sample.typeface, pinned: sample.pinned, order: sample.order, created: base.addingTimeInterval(sample.age - 86_400), modified: base.addingTimeInterval(sample.age))
            let url = folder.appendingPathComponent(id.fileName)
            try? Data(FrontMatter.serialize(note).utf8).write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: note.modified], ofItemAtPath: url.path)
        }
    }

    /// A model over its own temporary folder holding the first `count`
    /// samples, for All Notes' empty, one-note and ten-note stages. The
    /// caller removes the folder.
    private func allNotesModel(notes count: Int) -> (model: AppModel, folder: URL) {
        sampleModel(Array(Self.samples.prefix(count)))
    }

    /// A model over its own temporary folder holding these samples. The
    /// caller removes the folder.
    private func sampleModel(_ samples: [Sample]) -> (model: AppModel, folder: URL) {
        let stageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-preview-stage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stageFolder, withIntermediateDirectories: true)
        Self.write(samples, into: stageFolder, base: Date())
        let stage = AppModel(preferences: preferences, license: license, store: NoteStore(folder: stageFolder), watcher: FolderWatcher())
        stage.store.load(create: false)
        return (stage, stageFolder)
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
            let note = Note(id: id, text: "\(title)\nA line or two of text.", color: colors[index % colors.count], pinned: index == 0, order: index, created: base.addingTimeInterval(-Double(index) * 3600), modified: base.addingTimeInterval(-Double(index) * 3600))
            try? Data(FrontMatter.serialize(note).utf8).write(to: folder.appendingPathComponent(id.fileName))
        }
        let store = NoteStore(folder: folder)
        store.load(create: false)
        let model = AppModel(preferences: preferences, license: license, store: store, watcher: FolderWatcher())
        return model
    }

    /// The stage's screen: a 900 × 700 desktop.
    static let stageSize = CGSize(width: 900, height: 700)

    private func content(state: DeckState, toast: Bool, model: AppModel? = nil, scroll: CGFloat = 0) -> DeckContent {
        let model = model ?? self.model
        let notes = model.active
        let visible = CGRect(origin: .zero, size: Self.stageSize)
        let layout = DeckGeometry.layout(state: state, side: preferences.side, visibleFrame: visible, notes: notes.map(\.id), toast: toast, scroll: scroll)
        let open = state.openNote.flatMap { model.note($0) }
        let status: String
        if model.readOnly { status = model.readOnlyNotice } else if state.isEditing { status = "Editing…" } else { status = open.map { model.statusLine(for: $0.id) } ?? "" }
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
/// For the automation stages: the hover chip over a line of the open
/// note, and the refusal card where the deck is.
private struct DeckStage: View {
    let content: DeckContent
    let side: DeckSide
    let dark: Bool
    /// The link chip, above this line (1-based) of the open note's text.
    var chip: (label: String, line: Int)?
    /// The note-shaped refusal beside the deck's edge.
    var refusal: RefusalCard?

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
            if let chip, let note = content.layout.note {
                // Above the line, as the editor places it: the 12 pt inset,
                // the title line, then ~19 pt per line.
                LinkChip(label: chip.label)
                    .offset(x: frame.minX + note.minX + 12, y: size.height - frame.maxY + (frame.height - note.maxY) + 18 + CGFloat(chip.line - 2) * 19)
            }
            if let refusal {
                let x = side == .right ? frame.maxX - DeckMetrics().pillWidth - DeckMetrics().gap - RefusalCard.size.width : frame.minX + DeckMetrics().pillWidth + DeckMetrics().gap
                refusal.offset(x: x, y: (size.height - RefusalCard.size.height) / 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}
#endif
