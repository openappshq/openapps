import AppKit
import OpenNotesCore
import SwiftUI

final class SettingsWindowController: NSObject {
    private let model: AppModel
    private let preferences: Preferences
    private let loginItem: LoginItem
    private let hotkeys: HotkeyCenter
    private let diagnostics: () -> String
    private var window: NSWindow?
    /// Sections other wiring appends before About: the parity ticket's
    /// License and Updates. Set before the window first shows.
    var extraSections: [AnyView] = []

    init(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter, diagnostics: @escaping () -> String) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.hotkeys = hotkeys
        self.diagnostics = diagnostics
    }

    func show() {
        if window == nil {
            let root = SettingsView(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, diagnostics: diagnostics, extraSections: extraSections)
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenNotes Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.center()
            self.window = window
        }
        loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    let loginItem: LoginItem
    let hotkeys: HotkeyCenter
    let diagnostics: () -> String
    var extraSections: [AnyView] = []
    @State private var copied = false
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        if previewRendering {
            // The grouped form is AppKit-backed and draws nothing under
            // `ImageRenderer`: the same sections as cards, for the harness.
            VStack(alignment: .leading, spacing: Brand.Space.s16) {
                card { general }
                card { notes }
                card { about }
            }
            .padding(Brand.Space.s24)
            .toggleStyle(.checkbox)
            .frame(width: 540)
        } else {
            Form {
                general
                notes
                ForEach(Array(extraSections.enumerated()), id: \.offset) { _, section in section }
                about
            }
            .formStyle(.grouped)
            .frame(width: 540, height: 640)
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            content()
        }
        .padding(Brand.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
    }

    // MARK: - General

    private var general: some View {
        Section {
            LoginItemToggle(loginItem: loginItem)
            Picker(selection: $preferences.side) {
                ForEach(DeckSide.allCases, id: \.self) { side in
                    Text(side.title).tag(side)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deck side").font(Brand.body(14))
                    note("The edge the notes dock to.")
                }
            }
            Picker(selection: $preferences.display) {
                ForEach(DeckDisplay.allCases, id: \.self) { display in
                    Text(display.title).tag(display)
                }
            } label: {
                Text("Display").font(Brand.body(14))
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hotkey").font(Brand.body(14))
                    note("A new note from any app; Escape saves it.")
                }
                Spacer()
                HotkeyRecorder(hotkey: $preferences.hotkey, problem: hotkeys.problem)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes folder").font(Brand.body(14))
                    note(folderNote)
                }
                Spacer()
                if !preferences.usesDefaultFolder {
                    Button("Use Default") { preferences.resetFolder() }
                }
                Button("Choose…") { chooseFolder() }
            }
        } header: {
            MonoLabel("General")
        }
    }

    private var folderNote: String {
        var text = preferences.folderDisplayPath
        if model.store.folderIsMissing { text += " — can’t find this folder; nothing is read or written until it is back or another is chosen." }
        else { text += " · one .md file per note; iCloud Drive and an Obsidian vault work as well." }
        return text
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.folder
        panel.prompt = "Use this folder"
        panel.message = "Notes are read from and written to this folder as .md files. Files are never moved."
        if panel.runModal() == .OK, let url = panel.url { preferences.folder = url }
    }

    // MARK: - Notes

    private var notes: some View {
        Section {
            Picker(selection: $preferences.face) {
                ForEach(NoteFace.allCases, id: \.self) { face in
                    Text(face.title).tag(face)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Face for new notes").font(Brand.body(14))
                    note("Sans is Instrument Sans; Mono is IBM Plex Mono. Each note can switch its own (⌘⇧M).")
                }
            }
            Picker(selection: $preferences.color) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Text(color.title).tag(color)
                }
            } label: {
                Text("Color for new notes").font(Brand.body(14))
            }
            Picker(selection: $preferences.autoArchiveDays) {
                ForEach(AutoArchive.choices, id: \.self) { days in
                    Text(AutoArchive.title(days: days)).tag(days)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-archive untouched notes").font(Brand.body(14))
                    note("Unpinned notes not edited for that long leave the deck; they stay in the folder and in All Notes → Archived.")
                }
            }
        } header: {
            MonoLabel("Notes")
        }
    }

    // MARK: - About

    private var about: some View {
        Section {
            Text("OpenNotes reads and writes the notes folder above and nothing else. This build from source makes no network calls at all.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("MIT License. An OpenApps HQ original.")
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                Spacer()
                Button(copied ? "Copied" : "Copy Diagnostics") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(diagnostics(), forType: .string)
                    copied = true
                }
            }
        } header: {
            MonoLabel("About")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Brand.body(12))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Open at login" switch reflecting the real `SMAppService` status.
struct LoginItemToggle: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Toggle(isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setOn($0) })) {
                Text("Open OpenNotes at login")
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textPrimary)
            }
            .disabled(!loginItem.isAvailable)

            if !loginItem.isAvailable {
                note("Available once OpenNotes is installed as an app.")
            } else if loginItem.requiresApproval {
                HStack(spacing: Brand.Space.s8) {
                    note("macOS needs you to approve this in Login Items.")
                    Button("Open Login Items") { loginItem.openLoginItemsSettings() }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            if let error = loginItem.errorMessage {
                note(error)
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Brand.body(12))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
