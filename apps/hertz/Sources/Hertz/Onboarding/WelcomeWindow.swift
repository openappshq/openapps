import AppKit
import SwiftUI

/// Shown once after installation. Hertz needs no permissions, so the welcome
/// is one screen: what lives in the menu bar, the one choice to make (open at
/// login), and a way back to it from Settings.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private let loginItem: LoginItem
    private var window: NSWindow?

    init(preferences: Preferences, loginItem: LoginItem) {
        self.preferences = preferences
        self.loginItem = loginItem
    }

    func show() {
        if window == nil {
            let root = WelcomeView(loginItem: loginItem) { [weak self] in self?.window?.close() }
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: WelcomeView.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to Hertz"
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.contentView = hostingView
            window.delegate = self
            window.center()
            self.window = window
        }
        loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct WelcomeView: View {
    static let size = CGSize(width: 560, height: 520)

    let loginItem: LoginItem
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            HStack(alignment: .center, spacing: Brand.Space.s16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Brand.Space.s4) {
                    Text("Hertz is in your menu bar.")
                        .font(Brand.display(32))
                        .foregroundStyle(Brand.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Click the pulse to see what your Mac is doing right now.")
                        .font(Brand.body(15))
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            MenuBarPreview()

            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                point("CPU, memory, disk, network, battery and the process tree, read straight from the kernel every two seconds.")
                point("A diagnosis of what is slow, sleep blockers when something keeps the Mac awake, and a read-only cache scout.")
                point("No permissions to grant, no account, no telemetry. Nothing leaves this Mac.")
            }

            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                LoginItemToggle(loginItem: loginItem)
            }
            .padding(Brand.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()

            Spacer(minLength: 0)

            HStack {
                MonoLabel("Starts with your Mac · Settings has the rest")
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Brand.Space.s32)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Brand.canvas)
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Brand.Space.s8) {
            Circle()
                .fill(Brand.accentSolid)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(text)
                .font(Brand.body(14))
                .foregroundStyle(Brand.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A drawn menu bar with the Hertz item in it, so the window can point at
/// something the user has not clicked yet.
private struct MenuBarPreview: View {
    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            Spacer()
            Image(systemName: "wifi").font(.system(size: 12))
            Image(systemName: "battery.75percent").font(.system(size: 13))
            HStack(spacing: 5) {
                Image(nsImage: AppResources.menuBarImage())
                    .renderingMode(.template)
                Text("12%").font(.system(size: 12).monospacedDigit())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Brand.accentSubtle))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.accentSolid, lineWidth: 1))
            Text("Tue 9:41").font(.system(size: 12))
        }
        .foregroundStyle(Brand.textPrimary)
        .padding(.horizontal, Brand.Space.s12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).fill(Brand.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The menu bar, with the Hertz pulse and its CPU readout on the right")
    }
}
