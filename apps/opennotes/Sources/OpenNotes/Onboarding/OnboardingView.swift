import AppKit
import OpenNotesCore
import SwiftUI

/// The setup guide, in the same shape as Hertz's, OpenReaction's and
/// macPaper's: welcome, one step per permission (OpenNotes has none, and
/// says so), where the notes live, the login item, tips.
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
        case .files: FilesStep(model: model)
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
        (.files, "Files"),
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
                Text("Notes at the edge of your screen.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Move the pointer to the \(model.preferences.side == .right ? "right" : "left") edge and the deck fans out; press \(hotkeyText) in any app for a new note. Every note is a plain Markdown file in a folder you can see.")
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
            MonoLabel("Under a minute · Nothing is uploaded")
        }
        .padding(Brand.Space.s48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var hotkeyText: String {
        model.preferences.hotkey?.displayString ?? "the hotkey"
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

/// The step every app has one of per permission. OpenNotes has none: it
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
                Text("The deck is a window of OpenNotes’ own at the screen edge, the hotkey is a system hotkey, and the notes are files in a folder you chose. None of that needs a permission, so macOS won’t ask for one.")
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
                fact("The notes folder you chose", "Where your notes live: one .md file per note, watched for changes you make elsewhere. Beyond it OpenNotes keeps only its own settings and, in official builds, its license and update records under Library.")
                fact("What you paste", "Pasted text lands in the note as plain text; the pasteboard is read only when you paste.")
            }
            .padding(Brand.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardSurface())

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
        GuideFact(title: title, detail: detail)
    }
}

// MARK: - Files

/// "Your notes are files": where they live — On this Mac, iCloud Drive
/// (offered while it is reachable) or any folder — chosen here as in
/// Settings, and that an Obsidian vault can be the folder.
private struct FilesStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                MonoLabel("Files")
                Text("Your notes are files.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Each note is one Markdown file with a short front matter for its color, order and dates. Open them in any editor, back them up, grep them; OpenNotes notices changes made elsewhere and never deletes a note you wrote (the one file it removes is a new note you closed empty). Keep them in iCloud Drive and they are on every Mac signed in to it.")
                    .font(Brand.body(16))
                    .lineSpacing(4)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                StorageChoiceView(
                    current: model.preferences.storage, iCloudAvailable: Preferences.iCloudIsAvailable,
                    folderPath: model.preferences.folderDisplayPath, folderMissing: model.folderIsMissing(),
                    readOnly: !model.license.hasAccess(), notice: model.storageNotice(),
                    onChoose: { model.onChooseStorage?($0) }
                )
                Text("Switching copies the notes you have to the new folder; nothing is moved or removed. Change it any time in Settings → General.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Brand.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardSurface())

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
                    ? "The deck and the hotkey only work while OpenNotes runs. It opens at login and stays in the menu bar; there is nothing else it does in the background."
                    : "The deck and the hotkey only work while OpenNotes runs. Turn this on and it opens at login and stays in the menu bar; there is nothing else it does in the background.")
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
            .modifier(CardSurface())

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
            EdgePreview(side: model.preferences.side)
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                Text("You’re all set.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                tip("keyboard", "\(model.preferences.hotkey?.displayString ?? "The hotkey") makes a new note from any app and puts the caret in it; Escape saves it and slides it back. Change the hotkey in Settings → General.")
                tip("rectangle.righthalf.inset.filled", "Rest the pointer on the \(model.preferences.side == .right ? "right" : "left") edge and the deck fans out; click a tab to open a note, click anywhere else to close it; drag a tab up or down to reorder. ⌘W moves to the next note, ⌘⇧A archives, ⌘⇧P pins.")
                tip("list.bullet.rectangle", "⌥⌘L opens All Notes: search, Active and Archived, drag to reorder, and Export or Reveal in Finder for any note.")
                tip("eye.slash", model.preferences.hideFromScreenSharing
                    ? "OpenNotes asks macOS to leave your notes out of screen captures while you see them as usual — not a guarantee, some capture tools ignore it. Settings → General turns that off."
                    : "Settings → General can ask macOS to leave your notes out of screen captures while you see them as usual — not a guarantee, some capture tools ignore it.")
                if Licensing.isCompiledIn {
                    tip("key", "The trial, buying a license and entering a key live under Settings → License. When the trial ends nothing opens on its own: your notes stay readable and exportable, and writing waits for a license.")
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back", action: model.back)
                    .buttonStyle(LinkButtonStyle())
                Spacer()
                Button("Open All Notes") { model.onOpenAllNotes?() }
                    .buttonStyle(LinkButtonStyle())
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

/// A drawn screen with the deck's pill on its edge, so the window can
/// point at something the user has not hovered yet.
private struct EdgePreview: View {
    let side: DeckSide

    var body: some View {
        ZStack(alignment: side == .right ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                .fill(Brand.surface)
            VStack(spacing: 4) {
                ForEach([NoteColor.coral, .yellow, .mint, .sky], id: \.self) { color in
                    Capsule().fill(Brand.tab(color)).frame(width: 4, height: 12)
                }
            }
            .frame(width: 12, height: 72)
            .background(Color.black.opacity(0.62), in: UnevenRoundedRectangle(
                topLeadingRadius: side == .right ? 6 : 0, bottomLeadingRadius: side == .right ? 6 : 0,
                bottomTrailingRadius: side == .right ? 0 : 6, topTrailingRadius: side == .right ? 0 : 6, style: .continuous
            ))
            .overlay(alignment: side == .right ? .leading : .trailing) {
                Image(systemName: side == .right ? "arrow.right" : "arrow.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Brand.accentSolid)
                    .offset(x: side == .right ? -22 : 22)
            }
        }
        .frame(height: 96)
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.borderSubtle, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A screen with the OpenNotes pill on its \(side == .right ? "right" : "left") edge")
    }
}

/// A titled line in a guide card.
private struct GuideFact: View {
    let title: String
    let detail: String

    var body: some View {
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

/// The guide's card: a surface with a subtle rim.
private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.borderSubtle, lineWidth: 1))
    }
}
