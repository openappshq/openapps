import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let hostingView = NSHostingView(rootView: OnboardingView(
                controller: controller,
                permissions: controller.permissions,
                onClose: { [weak self] in self?.window?.close() }
            ))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to OpenReaction"
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.contentView = hostingView
            window.center()
            self.window = window
        }
        controller.permissions.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let controller: AppController
    let permissions: PermissionMonitor
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            header
            VStack(spacing: Brand.Space.s12) {
                PermissionRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Finds the text cursor so suggestions appear beside it, and types the emoji you choose.",
                    actionTitle: "Open Accessibility settings",
                    isGranted: permissions.accessibility,
                    isAwaiting: permissions.awaiting.contains(.accessibility),
                    action: { permissions.openSettings(for: .accessibility) }
                )
                PermissionRow(
                    symbol: "keyboard",
                    title: "Input Monitoring",
                    detail: "Notices when you type a colon and a shortcode, so the picker can open.",
                    actionTitle: "Open Input Monitoring settings",
                    isGranted: permissions.inputMonitoring,
                    isAwaiting: permissions.awaiting.contains(.inputMonitoring),
                    action: { permissions.openSettings(for: .inputMonitoring) }
                )
            }
            footer
        }
        .padding(.horizontal, Brand.Space.s32)
        .padding(.top, Brand.Space.s48)
        .padding(.bottom, Brand.Space.s32)
        .frame(width: 560, alignment: .leading)
        .background(Brand.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            Text("Type :tada: anywhere.")
                .font(Brand.display(40))
                .lineSpacing(0)
                .foregroundStyle(Brand.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("OpenReaction suggests emoji when you type a shortcode in any app. It needs two macOS permissions. What you type is matched on this Mac and never saved or sent anywhere.")
                .font(Brand.body(16))
                .lineSpacing(4)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(alignment: .center, spacing: Brand.Space.s12) {
            VStack(alignment: .leading, spacing: Brand.Space.s4) {
                Text(footerTitle)
                    .font(Brand.body(14, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
                Text(footerDetail)
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Brand.Space.s12)
            if controller.needsRelaunch {
                Button("Relaunch OpenReaction") { controller.relaunch() }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button(controller.isReady ? "Done" : "Close", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var footerTitle: String {
        if controller.isReady { return "You're set." }
        if controller.needsRelaunch { return "One more step." }
        return "OpenReaction stays in the menu bar."
    }

    private var footerDetail: String {
        if controller.isReady { return "Try typing :tada: in any text field." }
        if controller.needsRelaunch { return "macOS has granted access, but OpenReaction needs to restart to use it." }
        return "Suggestions start as soon as both permissions are on."
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let isGranted: Bool
    let isAwaiting: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Space.s16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Brand.textPrimary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Brand.Space.s4) {
                Text(title)
                    .font(Brand.body(16, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
                Text(detail)
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Brand.Space.s12) {
                    status
                    Spacer(minLength: 0)
                    if !isGranted {
                        Button(actionTitle, action: action)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, Brand.Space.s8)
            }
        }
        .padding(Brand.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .animation(.easeOut(duration: Brand.Motion.standard), value: isGranted)
    }

    @ViewBuilder private var status: some View {
        if isGranted {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(Brand.mono(13, medium: true))
                .foregroundStyle(Brand.successSolid)
                .padding(.horizontal, Brand.Space.s8)
                .frame(minHeight: 24)
                .background(Brand.successSubtle, in: RoundedRectangle(cornerRadius: Brand.Radius.small, style: .continuous))
        } else if isAwaiting {
            Label("Waiting for permission", systemImage: "hourglass")
                .font(Brand.mono(13))
                .foregroundStyle(Brand.textSecondary)
        } else {
            Label("Not allowed yet", systemImage: "circle.dashed")
                .font(Brand.mono(13))
                .foregroundStyle(Brand.textSecondary)
        }
    }
}
