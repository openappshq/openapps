import AppKit
import MacPaperCore
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let loginItem: LoginItem
    private let hotkeys: HotkeyCenter
    private let diagnostics: () -> String
    private var window: NSWindow?

    init(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter, diagnostics: @escaping () -> String) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.hotkeys = hotkeys
        self.diagnostics = diagnostics
    }

    func show() {
        if window == nil {
            let root = SettingsView(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, diagnostics: diagnostics)
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "macPaper Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            #if OPENAPPS_LICENSING
            // The trial pill goes in the title bar here (the licensing ticket).
            #endif
            window.center()
            self.window = window
        }
        loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Settings → License: the licensing ticket scrolls to the section.
    func showLicense(keyField: Bool = false) {
        show()
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    let loginItem: LoginItem
    let hotkeys: HotkeyCenter
    let diagnostics: () -> String
    @State private var copied = false
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        if previewRendering {
            // The grouped form is AppKit-backed and draws nothing under
            // `ImageRenderer`: the same sections as cards, switches as
            // checkboxes, for the preview harness only.
            VStack(alignment: .leading, spacing: Brand.Space.s16) {
                card { general }
                card { wallpapers }
                card { about }
            }
            .padding(Brand.Space.s24)
            .toggleStyle(.checkbox)
            .frame(width: 540)
        } else {
            Form {
                general
                wallpapers
                #if OPENAPPS_LICENSING
                // LicenseSection(license:navigation:) — the licensing ticket.
                #endif
                about
            }
            .formStyle(.grouped)
            .frame(width: 540, height: 760)
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
            Toggle(isOn: $preferences.notchEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notch panel").font(Brand.body(14))
                    note("Off: the menu-bar popover only.")
                }
            }
            Picker(selection: $preferences.hostDisplay) {
                ForEach(HostDisplay.allCases, id: \.self) { host in
                    Text(host.title).tag(host)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Host display").font(Brand.body(14))
                    note(hostNote)
                }
            }
            .disabled(!preferences.notchEnabled)
            Picker(selection: $preferences.trigger) {
                ForEach(PanelTrigger.allCases, id: \.self) { trigger in
                    Text(trigger.title).tag(trigger)
                }
            } label: {
                Text("Open on").font(Brand.body(14))
            }
            .disabled(!preferences.notchEnabled)
            Picker(selection: $preferences.direction) {
                ForEach(PanelDirection.allCases, id: \.self) { direction in
                    Text(direction.title + (direction.isRendered ? "" : " (coming later)")).tag(direction)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Direction").font(Brand.body(14))
                    if !preferences.direction.isRendered {
                        note("This version opens down; the choice is kept for a later release.")
                    }
                }
            }
            .disabled(!preferences.notchEnabled)
            Picker(selection: $preferences.width) {
                ForEach(PanelWidth.allCases, id: \.self) { width in
                    Text("\(width.title) · \(Int(width.points)) pt").tag(width)
                }
            } label: {
                Text("Width").font(Brand.body(14))
            }
            .disabled(!preferences.notchEnabled)
            Toggle(isOn: $preferences.hideInFullscreen) {
                Text("Hide in fullscreen").font(Brand.body(14))
            }
            .disabled(!preferences.notchEnabled)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hotkey").font(Brand.body(14))
                    note("Opens and closes the panel anywhere; the popover when the panel can’t show.")
                }
                Spacer()
                HotkeyRecorder(hotkey: $preferences.hotkey, problem: hotkeys.problem)
            }
        } header: {
            MonoLabel("General")
        }
    }

    private var hostNote: String {
        let notched = model.displays.filter(\.hasNotch)
        switch preferences.hostDisplay {
        case .notchDisplay:
            return notched.isEmpty ? "No display has a notch right now: the menu-bar popover carries everything." : "The panel is on \(notched[0].name)."
        case .mainDisplay:
            return model.displays.first(where: \.isMain).map { "The panel is on \($0.name)" + ($0.hasNotch ? "." : ", from the top center.") } ?? ""
        case .everyNotchedDisplay:
            return notched.isEmpty ? "No display has a notch right now." : "One panel on each: \(notched.map(\.name).joined(separator: ", "))."
        }
    }

    // MARK: - Wallpapers

    private var wallpapers: some View {
        Section {
            Picker(selection: $preferences.shuffleInterval) {
                ForEach(ShuffleInterval.allCases, id: \.self) { interval in
                    Text(interval.title).tag(interval)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle").font(Brand.body(14))
                    note("A new wallpaper on a schedule; the first one is one interval after the last apply.")
                }
            }
            Toggle(isOn: $preferences.favoritesOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Favorites only").font(Brand.body(14))
                    note(model.favoriteList.isEmpty ? "No favorites yet: shuffle picks at random until you star one." : "\(model.favoriteList.count) favorite\(model.favoriteList.count == 1 ? "" : "s").")
                }
            }
            Toggle(isOn: $preferences.sameOnAllDisplays) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Same on all displays").font(Brand.body(14))
                    note("Off: each display keeps its own, Apply offers this display or all, and Shuffle gives every display a different one.")
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export folder").font(Brand.body(14))
                    note(preferences.exportFolder.path(percentEncoded: false).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                }
                Spacer()
                Button("Choose…") { chooseExportFolder() }
            }
        } header: {
            MonoLabel("Wallpapers")
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.exportFolder
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url { preferences.exportFolder = url }
    }

    // MARK: - About

    private var about: some View {
        Section {
            Text(LicensingCopy.network)
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
                Text("Open macPaper at login")
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textPrimary)
            }
            .disabled(!loginItem.isAvailable)

            if !loginItem.isAvailable {
                note("Available once macPaper is installed as an app.")
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
