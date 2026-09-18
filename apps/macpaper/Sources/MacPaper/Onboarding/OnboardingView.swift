import AppKit
import MacPaperCore
import SwiftUI

/// The setup guide, in the same shape as Hertz's and OpenReaction's:
/// welcome, where the panel lives, one step per permission (macPaper has
/// none, and says so), the login item, tips.
struct OnboardingView: View {
    static let size = CGSize(width: 600, height: 600)

    let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.step != .welcome {
                StepProgress(step: model.step)
                    .padding(.horizontal, Brand.Space.s32)
                    .padding(.top, Brand.Space.s48)
                    .transition(.opacity)
            }
            ZStack {
                stepView
                    .id(model.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.canvas)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .panel: PanelStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .loginItem: LoginItemStep(model: model)
        case .tips: TipsStep(model: model)
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -24))
            )
    }
}

// MARK: - Progress

private struct StepProgress: View {
    let step: GuideStep

    private let steps: [(GuideStep, String)] = [
        (.panel, "Panel"),
        (.permissions, "Permissions"),
        (.loginItem, "Login"),
        (.tips, "Tips"),
    ]

    var body: some View {
        HStack(spacing: Brand.Space.s16) {
            ForEach(steps, id: \.0) { item, title in
                let isCurrent = item == step
                let isComplete = item < step
                VStack(alignment: .leading, spacing: Brand.Space.s8) {
                    Capsule()
                        .fill(isCurrent ? Brand.accentSolid : (isComplete ? Brand.textPrimary : Brand.borderSubtle))
                        .frame(height: 3)
                    HStack(spacing: Brand.Space.s4) {
                        if isComplete {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        }
                        Text(title.uppercased())
                            .font(Brand.mono(11, medium: isCurrent))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isCurrent || isComplete ? Brand.textPrimary : Brand.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let index = (steps.firstIndex { $0.0 == step } ?? 0) + 1
        let title = steps.first { $0.0 == step }?.1 ?? ""
        return "Step \(index) of \(steps.count): \(title)"
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            Spacer(minLength: 0)
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                Text("macPaper is in your menu bar.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Click the menu-bar icon to make a wallpaper and put it on your desktop.")
                    .font(Brand.body(16))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = model.licenseLine {
                trial(line)
            }
            HStack(spacing: Brand.Space.s16) {
                Button("Get started", action: model.getStarted)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Skip for now", action: model.skip)
                    .buttonStyle(LinkButtonStyle())
            }
            Spacer(minLength: 0)
            MonoLabel("Under a minute · Wallpapers never leave this Mac")
        }
        .padding(Brand.Space.s48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Official builds: what the license reports now (the trial running,
    /// ended, a license), never a claim the state does not back. The pill
    /// shows where it stands, also when the guide is opened again later.
    private func trial(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Text(line)
                .font(Brand.body(14))
                .lineSpacing(3)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let badge = model.licenseBadge {
                LicensePill(label: badge) { model.onOpenLicense?() }
            }
        }
    }
}

// MARK: - Permissions

/// The step every app has one of per permission. macPaper has none: it
/// says so, and what it touches instead.
private struct PermissionsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                MonoLabel("Permissions")
                Text("Nothing to grant.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("macPaper draws every wallpaper itself and sets it the way the Wallpaper settings pane does. The panel is a window under the menu-bar icon and the hotkey is a system hotkey. None of that needs a permission, so macOS won’t ask for one.")
                    .font(Brand.body(16))
                    .lineSpacing(4)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(LicensingCopy.network, systemImage: "lock")
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                fact("Your wallpaper", "Apply writes a PNG under macPaper’s Application Support folder and points the desktop at it. What macPaper set stays until you change it, even after it quits.")
                fact("The files you drop", "An image you pixelize is copied into macPaper’s imports folder so a favorite can render again. Nothing is uploaded.")
            }
            .padding(Brand.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()

            Spacer(minLength: 0)
            HStack(spacing: Brand.Space.s12) {
                Button("Continue", action: model.advance)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Spacer(minLength: 0)
                Button("Skip for now", action: model.skip)
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(Brand.Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fact(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Brand.Space.s4) {
            Text(title)
                .font(Brand.body(14, weight: 600))
                .foregroundStyle(Brand.textPrimary)
            Text(detail)
                .font(Brand.body(13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Login item

/// "Starts with your Mac", from the real `SMAppService` state: on by
/// default on a fresh install, and the user's switch from here on.
private struct LoginItemStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                MonoLabel("Login")
                Text(model.loginItem.isOn ? "Starts with your Mac." : "Can start with your Mac.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(model.loginItem.isOn
                    ? "The panel, the hotkey and a scheduled shuffle only work while macPaper runs. It opens at login and stays in the menu bar; there is nothing else it does in the background."
                    : "The panel, the hotkey and a scheduled shuffle only work while macPaper runs. Turn this on and it opens at login and stays in the menu bar; there is nothing else it does in the background.")
                    .font(Brand.body(16))
                    .lineSpacing(4)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                LoginItemToggle(loginItem: model.loginItem)
                Text("Change it any time in Settings → General, or in System Settings → Login Items.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Brand.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()

            Spacer(minLength: 0)
            HStack(spacing: Brand.Space.s12) {
                Button("Continue", action: model.advance)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Back", action: model.back)
                    .buttonStyle(LinkButtonStyle())
                Spacer(minLength: 0)
                Button("Skip for now", action: model.skip)
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(Brand.Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tips

private struct TipsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            MenuBarPreview()
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                Text("You’re all set.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                tip("rectangle.topthird.inset.filled", "The panel opens under the menu-bar icon from a click on it\(model.shortcut.map { " or \($0)" } ?? ""). Settings → General sets its width, whether it hides in fullscreen, and the shortcut.")
                tip("dice", "Every wallpaper is a document with a seed. The dice picks another; click the seed to type one back in and get the exact same wallpaper, on any Mac.")
                tip("rectangle.on.rectangle", "With “Same on all displays” off, each display keeps its own wallpaper: Apply offers this display or all of them, and Shuffle gives every display a different one. A favorite is the document, so it renders again at any display’s size.")
                if Licensing.isCompiledIn {
                    tip("key", "The trial, buying a license and entering a key live under Settings → License. Nothing opens on its own when the trial ends; the panel says so, and the wallpaper you applied stays.")
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back", action: model.back)
                    .buttonStyle(LinkButtonStyle())
                Spacer()
                if Licensing.isCompiledIn {
                    Button("Open License settings") { model.onOpenLicense?() }
                        .buttonStyle(LinkButtonStyle())
                } else {
                    Button("Open Settings") { model.onOpenSettings?() }
                        .buttonStyle(LinkButtonStyle())
                }
                Button("Done", action: model.finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Brand.Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(Brand.body(14))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.accentText)
                .frame(width: 18)
        }
    }
}

/// A drawn menu bar with the macPaper item in it, so the window can point
/// at something the user has not clicked yet.
private struct MenuBarPreview: View {
    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            Image(systemName: "apple.logo").font(.system(size: 12, weight: .semibold))
            Text("Finder").font(.system(size: 12, weight: .semibold))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 12))
            Image(nsImage: AppResources.menuBarImage())
                .renderingMode(.template)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Brand.accentSubtle))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.accentSolid, lineWidth: 1))
            Text("Tue 9:41").font(.system(size: 12))
        }
        .padding(.horizontal, Brand.Space.s12)
        .foregroundStyle(Brand.textPrimary)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).fill(Brand.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The menu bar, with the macPaper item on the right")
    }
}
