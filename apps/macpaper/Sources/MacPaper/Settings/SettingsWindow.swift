import AppKit
import MacPaperCore
import OpenAppsLicensing
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let loginItem: LoginItem
    private let hotkeys: HotkeyCenter
    private let diagnostics: () -> String
    private var window: NSWindow?
    /// Scroll requests (Settings → License); the sections the licensing
    /// wiring appends read it.
    let navigation = SettingsNavigation()
    /// Sections other wiring appends before About: the licensing wiring's
    /// License and Updates (LicensingLaunch.swift). Set before the window
    /// first shows.
    var extraSections: [AnyView] = []
    var screenSaver: any ScreenSaverInstaller = SaverInstaller()
    /// "Show setup guide" under About.
    var showGuide: () -> Void = {}
    /// The trial pill at the trailing end of the title bar, while there is
    /// something to say; nil (a build without licensing) adds nothing.
    var titleBarBadge: (() -> LicenseBadge.Label?)?

    init(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter, diagnostics: @escaping () -> String) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.hotkeys = hotkeys
        self.diagnostics = diagnostics
    }

    func show() {
        if window == nil {
            var root = SettingsView(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, diagnostics: diagnostics, extraSections: extraSections, screenSaver: screenSaver)
            root.navigation = navigation
            root.showGuide = showGuide
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
            if let titleBarBadge {
                window.addTitlebarAccessoryViewController(LicensePillAccessory(badge: titleBarBadge) { [weak self] in
                    self?.showLicense()
                })
            }
            window.center()
            self.window = window
        }
        loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Settings → License: the pill, the panel's card and the setup guide
    /// land here. `keyField` puts the cursor in the key field.
    func showLicense(keyField: Bool = false) {
        show()
        navigation.reveal(.license, keyField: keyField)
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    let loginItem: LoginItem
    let hotkeys: HotkeyCenter
    let diagnostics: () -> String
    var extraSections: [AnyView] = []
    var screenSaver: any ScreenSaverInstaller = SaverInstaller()
    /// Scroll requests (Settings → License); the preview harness never scrolls.
    var navigation = SettingsNavigation()
    var showGuide: () -> Void = {}
    @State private var copied = false
    @State private var saverNote: String?
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if previewRendering {
            // The grouped form is AppKit-backed and draws nothing under
            // `ImageRenderer`: the same sections as cards, switches as
            // checkboxes, for the preview harness only.
            VStack(alignment: .leading, spacing: Brand.Space.s16) {
                card { general }
                card { wallpapers }
                card { desktop }
                card { about }
            }
            .padding(Brand.Space.s24)
            .toggleStyle(.checkbox)
            .frame(width: 540)
        } else {
            ScrollViewReader { proxy in
                Form {
                    general
                    wallpapers
                    desktop
                    ForEach(Array(extraSections.enumerated()), id: \.offset) { _, section in section }
                    about
                }
                .onChange(of: navigation.request) {
                    guard let anchor = navigation.anchor else { return }
                    withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 540, height: 820)
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
            Picker(selection: $preferences.width) {
                ForEach(PanelWidth.allCases, id: \.self) { width in
                    Text("\(width.title) · \(Int(PanelMetrics.width(for: width))) pt").tag(width)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Width").font(Brand.body(14))
                    note("As tall as its content, up to what the display allows; grows to fit its longest label.")
                }
            }
            Toggle(isOn: $preferences.hideInFullscreen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide in fullscreen").font(Brand.body(14))
                    note("An open panel closes when the app in front goes fullscreen; the menu bar icon and the shortcut still open it there.")
                }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show panel").font(Brand.body(14))
                    note("The shortcut shows and hides the panel from anywhere, under the menu bar icon. Also in the icon’s menu.")
                }
                Spacer()
                HotkeyRecorder(hotkey: $preferences.hotkey, problem: hotkeys.problem)
            }
        } header: {
            MonoLabel("General")
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
                    note(model.favoriteList.isEmpty ? "No favorites yet: shuffle draws a curated recipe until you star one." : "\(model.favoriteList.count) favorite\(model.favoriteList.count == 1 ? "" : "s").")
                }
            }
            Toggle(isOn: $preferences.sameOnAllDisplays) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Same on all displays").font(Brand.body(14))
                    note("Off: each display keeps its own, Apply offers this display or all, and Shuffle gives every display a different one.")
                }
            }
            Toggle(isOn: $preferences.keepApplied) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it applied").font(Brand.body(14))
                    note("Re-applies macPaper’s own file when macOS shows something else: at launch, on wake, on unlock, when the Space or the displays change. Displays applied “this Space only” are left alone.")
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never show").font(Brand.body(14))
                    note(model.blockedCount == 0 ? "Nothing blocked. “Never show this” in the panel keeps a wallpaper out of shuffle." : "\(model.blockedCount) blocked from shuffle.")
                }
                Spacer()
                Button("Clear") { model.clearBlocklist() }
                    .disabled(model.blockedCount == 0)
            }
            note("Spaces: “Every Space” is kept by the pin as each Space becomes active. “This Space only” applies once; macOS gives no public Space identity, so it cannot be followed if System Settings → Desktop & Dock → “Automatically rearrange Spaces” is on.")
        } header: {
            MonoLabel("Wallpapers")
        }
    }

    // MARK: - Desktop extras

    private var desktop: some View {
        Section {
            Picker(selection: $preferences.clockStyle) {
                ForEach(ClockStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clock").font(Brand.body(14))
                    note("On the wallpaper layer, under the icons; hidden in fullscreen.")
                }
            }
            Picker(selection: $preferences.clockPosition) {
                ForEach(ClockPosition.allCases, id: \.self) { position in
                    Text(position.title).tag(position)
                }
            } label: {
                Text("Position").font(Brand.body(14))
            }
            .disabled(preferences.clockStyle == .off)
            Picker(selection: $preferences.clockSize) {
                ForEach(ClockSize.allCases, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            } label: {
                Text("Size").font(Brand.body(14))
            }
            .disabled(preferences.clockStyle == .off)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen saver").font(Brand.body(14))
                    note(saverNote ?? (screenSaver.isInstalled ? "Installed in ~/Library/Screen Savers. Choose it in System Settings → Screen Saver." : (screenSaver.isAvailable ? "Shows the applied stills, and crossfades through the favorites. Installs into ~/Library/Screen Savers; you choose it in System Settings → Screen Saver." : "Available in the packaged app.")))
                }
                Spacer()
                Button(screenSaver.isInstalled ? "Reinstall" : "Install screen saver") {
                    do {
                        try screenSaver.install()
                        saverNote = "Installed. Choose macPaper in System Settings → Screen Saver."
                    } catch {
                        saverNote = "Couldn’t install: \(error.localizedDescription)"
                    }
                }
                .disabled(!screenSaver.isAvailable)
            }
        } header: {
            MonoLabel("Desktop")
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
            HStack(alignment: .top) {
                Text(LicensingCopy.network)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Show setup guide", action: showGuide)
            }
            Text("Lock screen: since macOS Sonoma it shows the current desktop wallpaper, and there is no public way to set a separate one — so the lock screen follows the desktop, a light/dark pair included.")
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
