import AppKit
import HertzCore
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: MetricsModel
    private let preferences: Preferences
    private let loginItem: LoginItem
    private let showWelcome: () -> Void
    private var window: NSWindow?

    init(model: MetricsModel, preferences: Preferences, loginItem: LoginItem, showWelcome: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.showWelcome = showWelcome
    }

    func show() {
        if window == nil {
            let root = SettingsView(model: model, preferences: preferences, loginItem: loginItem, showWelcome: showWelcome)
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
            window.center()
            self.window = window
        }
        loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    let model: MetricsModel
    @Bindable var preferences: Preferences
    let loginItem: LoginItem
    let showWelcome: () -> Void
    @State private var copied = false
    @State private var copiedCommand = false

    var body: some View {
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

            // TODO: adopt packages/openapps-updater (the shared signed-feed
            // updater with "Check now" and opt-in automatic checks) once it is
            // on main; until then Homebrew is the update path (RELEASES.md).
            Section {
                LabeledContent("Version") {
                    Text(Diagnostics.versionString).font(Brand.mono(12)).textSelection(.enabled)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Brand.Space.s4) {
                        Text("Hertz is installed and updated with Homebrew. It never checks for updates on its own.")
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Diagnostics.upgradeCommand)
                            .font(Brand.mono(12))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(copiedCommand ? "Copied" : "Copy Command") {
                        copyToPasteboard(Diagnostics.upgradeCommand)
                        copiedCommand = true
                    }
                }
            } header: {
                MonoLabel("Updates")
            }

            Section {
                HStack(alignment: .top) {
                    Text("Everything is read from this Mac's kernel and shown here. Nothing is stored or sent anywhere.")
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Welcome Window…", action: showWelcome)
                }
                HStack {
                    Text("MIT License. An OpenApps HQ original.")
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        copyToPasteboard(Diagnostics.text(model: model, loginItem: loginItem))
                        copied = true
                    }
                }
            } header: {
                MonoLabel("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
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
    static let upgradeCommand = "brew upgrade --cask hertz"

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static func text(model: MetricsModel, loginItem: LoginItem) -> String {
        [
            "Hertz \(versionString)",
            "Open at login: \(loginItem.status.rawValue)",
            "",
            model.diagnosticReport,
        ].joined(separator: "\n")
    }
}
