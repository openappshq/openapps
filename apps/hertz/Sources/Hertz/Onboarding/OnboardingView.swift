import AppKit
import HertzCore
import SwiftUI

/// The setup guide, in the same shape as OpenReaction's: welcome, one step
/// per permission (Hertz has none, and says so), the login item, tips.
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
                Text("Hertz is in your menu bar.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Click the pulse to see what your Mac is doing right now.")
                    .font(Brand.body(16))
                    .foregroundStyle(Brand.textSecondary)
            }
            if Licensing.isCompiledIn {
                trial
            }
            HStack(spacing: Brand.Space.s16) {
                Button("Get started", action: model.getStarted)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Skip for now", action: model.skip)
                    .buttonStyle(LinkButtonStyle())
            }
            Spacer(minLength: 0)
            MonoLabel("Under a minute · Readings never leave this Mac")
        }
        .padding(Brand.Space.s48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Official builds: the trial started by itself. The pill shows where it
    /// stands, also when the guide is opened again later.
    private var trial: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Text("Your free 3-day trial started when you opened Hertz — no signup. Buy a license any time in Settings → License.")
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

/// The step every app has one of per permission. Hertz has none: it says
/// so, and what it reads instead.
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
                Text("Hertz reads CPU, memory, disk, network, battery and the process list straight from the kernel — Mach, libproc, IOKit, the SMC and CoreWLAN. None of that needs a permission, so macOS won’t ask for one.")
                    .font(Brand.body(16))
                    .lineSpacing(4)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(LicensingCopy.readings, systemImage: "lock")
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                fact("Read-only", "Hertz never terminates a process, clears a sleep blocker or deletes a cache. Those actions open Activity Monitor or the Finder.")
                fact("Wi-Fi name", "Newer macOS withholds the network’s name without Location access. Hertz doesn’t ask; the line is left out instead.")
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
                Text("A monitor is only useful while it runs. Hertz opens at login and stays in the menu bar; there is nothing else it does in the background.")
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
                tip("waveform.path.ecg", "The menu bar shows CPU usage next to the pulse. Settings → General can switch it to memory, or the pulse alone.")
                tip("rectangle.grid.1x2", "The dashboard is one stack of cards. Diagnosis, sleep blockers, processes and Cleanup Scout can be turned off under Settings → Dashboard; the vitals always show.")
                if Licensing.isCompiledIn {
                    tip("key", "The trial, buying a license and entering a key live under Settings → License. Nothing opens on its own when the trial ends; the dashboard says so.")
                }
                tip("menubar.arrow.up.rectangle", "Can’t see the icon? A full menu bar or the camera notch can hide it. Open Hertz again from Finder or Spotlight to reach its settings.")
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back", action: model.back)
                    .buttonStyle(LinkButtonStyle())
                Spacer()
                if Licensing.isCompiledIn {
                    Button("Open License settings") { model.onOpenLicense?() }
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
