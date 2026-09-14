import AppKit
import OpenReactionCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: AppController
    private let loginItem: LoginItem
    private let showOnboarding: () -> Void
    private var window: NSWindow?

    init(controller: AppController, loginItem: LoginItem, showOnboarding: @escaping () -> Void) {
        self.controller = controller
        self.loginItem = loginItem
        self.showOnboarding = showOnboarding
    }

    func show() {
        if window == nil {
            let hostingView = NSHostingView(rootView: SettingsView(
                controller: controller,
                loginItem: loginItem,
                showOnboarding: showOnboarding
            ))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenReaction Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.center()
            self.window = window
        }
        loginItem.refresh()
        controller.permissions.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    let controller: AppController
    let loginItem: LoginItem
    let showOnboarding: () -> Void
    @State private var copied = false

    var body: some View {
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
                    Button("Open Setup Guide…", action: showOnboarding)
                }
            } header: {
                MonoLabel("Permissions")
            }

            AppExclusionsSection(controller: controller)

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
        .formStyle(.grouped)
        // The app list makes the form taller than a screen; the form scrolls.
        .frame(width: 520, height: 640)
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
            string: "Emoji suggestions for every text field.\n\(controller.dataSourceSummary)\nMIT License. Nothing you type leaves this Mac.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
