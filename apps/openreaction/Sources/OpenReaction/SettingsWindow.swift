import AppKit
import OpenReactionCore
#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
#endif
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

    func reveal(_ anchor: Anchor) {
        self.anchor = anchor
        request += 1
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: AppController
    private let loginItem: LoginItem
    private let showOnboarding: () -> Void
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    #if OPENAPPS_LICENSING
    private let license: LicenseController
    #endif
    #if OPENAPPS_OFFICIAL
    var updates: Updates?
    #endif

    #if OPENAPPS_LICENSING
    init(controller: AppController, loginItem: LoginItem, license: LicenseController, showOnboarding: @escaping () -> Void) {
        self.controller = controller
        self.loginItem = loginItem
        self.license = license
        self.showOnboarding = showOnboarding
    }
    #else
    init(controller: AppController, loginItem: LoginItem, showOnboarding: @escaping () -> Void) {
        self.controller = controller
        self.loginItem = loginItem
        self.showOnboarding = showOnboarding
    }
    #endif

    func show() {
        if window == nil {
            #if OPENAPPS_LICENSING
            let root = SettingsView(controller: controller, loginItem: loginItem, license: license, navigation: navigation, showOnboarding: showOnboarding)
            #else
            let root = SettingsView(controller: controller, loginItem: loginItem, navigation: navigation, showOnboarding: showOnboarding)
            #endif
            #if OPENAPPS_OFFICIAL
            let hostingView = NSHostingView(rootView: root.showingUpdates(updates))
            #else
            let hostingView = NSHostingView(rootView: root)
            #endif
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenReaction Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            #if OPENAPPS_LICENSING
            // The trial pill, at the trailing end of the title bar.
            window.addTitlebarAccessoryViewController(LicensePillAccessory(badge: { [license] in license.badge }) { [weak self] in
                self?.showLicense()
            })
            #endif
            window.center()
            self.window = window
        }
        loginItem.refresh()
        controller.permissions.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Settings → License: the pill, the status menu's license line and the
    /// setup guide land here.
    func showLicense() {
        show()
        navigation.reveal(.license)
    }
}

private struct SettingsView: View {
    let controller: AppController
    let loginItem: LoginItem
    #if OPENAPPS_LICENSING
    let license: LicenseController
    #endif
    let navigation: SettingsNavigation
    let showOnboarding: () -> Void
    #if OPENAPPS_OFFICIAL
    var updates: Updates? = nil

    func showingUpdates(_ updates: Updates?) -> SettingsView {
        var view = self
        view.updates = updates
        return view
    }
    #endif
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
        // The app list makes the form taller than a screen; the form scrolls.
        .frame(width: 520, height: 640)
    }

    private var form: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) })) {
                    Text("Suggest emoji while typing").font(Brand.body(14))
                }
                LoginItemToggle(loginItem: loginItem)
            } header: {
                MonoLabel("General")
            }

            Section {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    LabeledContent {
                        PermissionStatusBadge(status: controller.permissions.status(kind))
                    } label: {
                        Text(kind.title).font(Brand.body(14))
                    }
                }
                HStack {
                    if controller.needsRelaunch {
                        Button("Relaunch OpenReaction") { controller.relaunch() }
                            .disabled(!controller.canRelaunch)
                    }
                    Spacer()
                    Button("Show setup guide", action: showOnboarding)
                }
            } header: {
                MonoLabel("Permissions")
            }

            #if OPENAPPS_LICENSING
            LicenseSection(license: license, anchor: SettingsNavigation.Anchor.license)
            #endif

            AppExclusionsSection(controller: controller)

            TypedReplacementSection(controller: controller)

            #if OPENAPPS_OFFICIAL
            if let updates {
                UpdatesSection(updates: updates)
            }
            #endif

            Section {
                LabeledContent("Version") {
                    Text(Diagnostics.versionString).font(Brand.mono(12)).textSelection(.enabled)
                }
                LabeledContent("Emoji data") {
                    Text(controller.dataSourceSummary)
                        .font(Brand.mono(12))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top) {
                    Text("OpenReaction remembers which emoji you pick, on this Mac only, to rank suggestions. It never keeps what you type.")
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Clear Usage History") { controller.clearUsageHistory() }
                        .disabled(!controller.hasUsageHistory)
                }
                HStack {
                    Text("MIT License.")
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(Diagnostics.text(controller: controller, loginItem: loginItem), forType: .string)
                        copied = true
                    }
                }
            } header: {
                MonoLabel("About")
            }
        }
    }
}

/// Plain-text state for bug reports. Only shown or copied on request.
@MainActor
enum Diagnostics {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static func text(controller: AppController, loginItem: LoginItem) -> String {
        let permissions = controller.permissions
        var lines: [String] = [
            "OpenReaction \(versionString)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Emoji data: \(controller.dataSourceSummary)",
        ]
        for kind in PermissionKind.allCases {
            lines.append("\(kind.title): \(permissions.status(kind))")
        }
        let tap = controller.isTapRunning ? "running" : "stopped"
        lines.append("Event tap: \(tap)\(controller.isEnabled ? "" : " (paused)")")
        lines.append("Open at login: \(loginItem.status.rawValue)")
        lines.append("Code identity: \(permissions.codeIdentity.prefix(16))")
        return lines.joined(separator: "\n")
    }

    static func showAboutPanel(controller: AppController) {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "Emoji suggestions for every text field.\n\(controller.dataSourceSummary)\nMIT License. Nothing you type leaves this Mac."
                + (Licensing.isCompiledIn ? "\n\n" + LicensingCopy.privacy : ""),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
