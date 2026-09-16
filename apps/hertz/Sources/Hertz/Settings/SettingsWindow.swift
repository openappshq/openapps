import AppKit
import HertzCore
import SwiftUI

/// A request to bring one part of the settings form into view.
@MainActor
@Observable
final class SettingsNavigation {
    enum Anchor: Hashable {
        case license
    }

    /// Incremented per request, so asking for the same anchor twice scrolls twice.
    private(set) var request = 0
    private(set) var anchor: Anchor?
    /// The request came from "Enter a key": the key field takes focus.
    private(set) var wantsKeyField = false

    func reveal(_ anchor: Anchor, keyField: Bool = false) {
        self.anchor = anchor
        wantsKeyField = keyField
        request += 1
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: MetricsModel
    private let preferences: Preferences
    private let loginItem: LoginItem
    private let showGuide: () -> Void
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    #if OPENAPPS_LICENSING
    private let license: LicenseController?
    #endif
    #if OPENAPPS_OFFICIAL
    /// The updater's wiring (RELEASES.md); nil when the official build has
    /// no feed or key in its Info.plist. Independent of the license.
    var updates: Updates?
    #endif

    #if OPENAPPS_LICENSING
    init(model: MetricsModel, preferences: Preferences, loginItem: LoginItem, license: LicenseController?, showGuide: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.license = license
        self.showGuide = showGuide
    }
    #else
    init(model: MetricsModel, preferences: Preferences, loginItem: LoginItem, showGuide: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.showGuide = showGuide
    }
    #endif

    func show() {
        if window == nil {
            #if OPENAPPS_LICENSING
            var root = SettingsView(model: model, preferences: preferences, loginItem: loginItem, license: license, navigation: navigation, showGuide: showGuide)
            #else
            var root = SettingsView(model: model, preferences: preferences, loginItem: loginItem, navigation: navigation, showGuide: showGuide)
            #endif
            #if OPENAPPS_OFFICIAL
            root.updates = updates
            #endif
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Hertz Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            #if OPENAPPS_LICENSING
            // The trial pill, at the trailing end of the title bar.
            if let license {
                window.addTitlebarAccessoryViewController(LicensePillAccessory(badge: { [license] in license.badge }) { [weak self] in
                    self?.showLicense()
                })
            }
            #endif
            window.center()
            self.window = window
        }
        loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Settings → License: the pill, the dashboard's card and the setup
    /// guide land here. `keyField` puts the cursor in the key field.
    func showLicense(keyField: Bool = false) {
        show()
        navigation.reveal(.license, keyField: keyField)
    }
}

private struct SettingsView: View {
    let model: MetricsModel
    @Bindable var preferences: Preferences
    let loginItem: LoginItem
    #if OPENAPPS_LICENSING
    let license: LicenseController?
    #endif
    #if OPENAPPS_OFFICIAL
    var updates: Updates? = nil
    #endif
    let navigation: SettingsNavigation
    let showGuide: () -> Void
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: navigation.request) {
                    guard let anchor = navigation.anchor else { return }
                    withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: Licensing.isCompiledIn ? 700 : 560)
    }

    private var form: some View {
        Form {
            Section {
                LoginItemToggle(loginItem: loginItem)
                Picker(selection: $preferences.menuBarReadout) {
                    ForEach(MenuBarReadout.allCases, id: \.self) { readout in
                        Text(readout.title).tag(readout)
                    }
                } label: {
                    Text("Menu bar shows").font(Brand.body(14))
                }
            } header: {
                MonoLabel("General")
            }

            Section {
                Toggle(isOn: $preferences.showsDiagnosis) {
                    Text("Diagnosis and recent events").font(Brand.body(14))
                }
                Toggle(isOn: $preferences.showsSleepBlockers) {
                    Text("Sleep blockers, when something holds the Mac awake").font(Brand.body(14))
                }
                Toggle(isOn: $preferences.showsProcesses) {
                    Text("Processes").font(Brand.body(14))
                }
                Toggle(isOn: $preferences.showsCleanupScout) {
                    Text("Cleanup Scout").font(Brand.body(14))
                }
                Text("CPU, memory, disk, network and battery are always shown.")
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
            } header: {
                MonoLabel("Dashboard")
            }

            #if OPENAPPS_LICENSING
            if let license {
                LicenseSection(license: license, navigation: navigation)
            }
            #endif

            // The shared updater in official builds (RELEASES.md, "In-app
            // updater"); a build from source has none and says so.
            #if OPENAPPS_OFFICIAL
            UpdatesSection(updates: updates)
            #else
            UpdatesSection()
            #endif

            Section {
                HStack(alignment: .top) {
                    Text(LicensingCopy.readings)
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Show setup guide", action: showGuide)
                }
                HStack {
                    Text("MIT License. An OpenApps HQ original.")
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        // Formatted inside the action: the readings part is
                        // the model's gate as of this click.
                        model.clipboard(Diagnostics.text(model: model, loginItem: loginItem))
                        copied = true
                    }
                }
            } header: {
                MonoLabel("About")
            }
        }
    }
}

/// "Open at login" switch reflecting the real `SMAppService` status.
struct LoginItemToggle: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Toggle(isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setOn($0) })) {
                Text("Open Hertz at login")
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textPrimary)
            }
            .disabled(!loginItem.isAvailable)

            if !loginItem.isAvailable {
                note("Available once Hertz is installed as an app.")
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

/// Plain-text state for bug reports. Only shown or copied on request.
enum Diagnostics {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static func text(model: MetricsModel, loginItem: LoginItem) -> String {
        text(model: model, loginStatus: loginItem.statusDescription)
    }

    /// Version, login state and the build's licensing flavour always; the
    /// readings only through the model's own gate (`diagnosticReport`),
    /// which refuses while the license does not allow them now.
    static func text(model: MetricsModel, loginStatus: String) -> String {
        [
            "Hertz \(versionString)",
            "Open at login: \(loginStatus)",
            "Licensing: \(Licensing.isCompiledIn ? "official build" : "compiled out (source build)")",
            "Readings: \(model.hasAccess ? "allowed" : "off (license)")",
            "",
            model.diagnosticReport,
        ].joined(separator: "\n")
    }
}
