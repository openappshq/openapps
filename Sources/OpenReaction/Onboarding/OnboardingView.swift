import AppKit
import OpenReactionCore
import SwiftUI

struct OnboardingView: View {
    static let size = CGSize(width: 640, height: 640)

    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.displayedStep != .welcome {
                StepProgress(step: model.displayedStep, permissions: model.permissions)
                    .padding(.horizontal, Brand.Space.s32)
                    .padding(.top, Brand.Space.s48)
                    .transition(.opacity)
            }
            ZStack {
                stepView
                    .id(model.displayedStep)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.canvas)
        .onChange(of: model.derivedStep) { model.sync() }
    }

    @ViewBuilder private var stepView: some View {
        switch model.displayedStep {
        case .welcome: WelcomeStep(model: model)
        case .accessibility: PermissionStep(model: model, kind: .accessibility)
        case .inputMonitoring: PermissionStep(model: model, kind: .inputMonitoring)
        case .tryIt: TryItStep(model: model)
        case .done: DoneStep(model: model)
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
    let step: OnboardingStep
    let permissions: PermissionMonitor

    private let steps: [(OnboardingStep, String)] = [
        (.accessibility, "Accessibility"),
        (.inputMonitoring, "Input Monitoring"),
        (.tryIt, "Try it"),
        (.done, "Done"),
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
                Text("Type :tada: anywhere.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Emoji suggestions in every app, right where you type.")
                    .font(Brand.body(16))
                    .foregroundStyle(Brand.textSecondary)
            }
            Button("Get started", action: model.getStarted)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
            MonoLabel("About a minute · Nothing leaves this Mac")
        }
        .padding(Brand.Space.s48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Permission

private struct PermissionStep: View {
    let model: OnboardingModel
    let kind: PermissionKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: PermissionStatus { model.permissions.status(kind) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.Space.s24) {
                VStack(alignment: .leading, spacing: Brand.Space.s12) {
                    MonoLabel("Permission \(kind == .accessibility ? 1 : 2) of 2")
                    Text("Allow \(kind.title)")
                        .font(Brand.display(40))
                        .foregroundStyle(Brand.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(why)
                        .font(Brand.body(16))
                        .lineSpacing(4)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(privacy, systemImage: "lock")
                        .font(Brand.body(14))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Brand.Space.s12) {
                    PermissionStatusBadge(status: status, celebrate: model.celebrating == kind)
                    if status == .requested {
                        Button("Check again") { model.permissions.refresh() }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
                .animation(Motion.standard(reduceMotion: reduceMotion), value: status)

                if status != .granted {
                    actions
                    if model.showHow.contains(kind) {
                        SettingsPaneIllustration(kind: kind)
                            .padding(Brand.Space.s16)
                            .frame(maxWidth: .infinity)
                            .cardSurface()
                            .transition(.opacity)
                    }
                    TroubleshootingList(model: model, kind: kind, topics: [.notWorking, .notListed, .afterUpdate])
                }
            }
            .padding(.horizontal, Brand.Space.s32)
            .padding(.vertical, Brand.Space.s32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Brand.Space.s12) {
            if status == .stale {
                Button(model.permissions.resetInProgress == kind ? "Resetting…" : "Reset permission") { model.reset(kind) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.permissions.canReset || model.permissions.resetInProgress != nil)
            } else {
                Button(status == .requested ? "Open System Settings again" : "Open System Settings") { model.request(kind) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Button(model.showHow.contains(kind) ? "Hide how" : "Show how") {
                withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                    if model.showHow.contains(kind) { model.showHow.remove(kind) } else { model.showHow.insert(kind) }
                }
            }
            .secondaryAction()
        }
    }

    private var why: String {
        switch kind {
        case .accessibility:
            "OpenReaction needs Accessibility to insert emoji where you type, and to find the text cursor so suggestions appear right beside it."
        case .inputMonitoring:
            "OpenReaction needs Input Monitoring to notice when you type a colon followed by a shortcode, like :tada."
        }
    }

    private var privacy: String {
        switch kind {
        case .accessibility:
            "It only looks at the text field you're typing in — never your screen, files or passwords."
        case .inputMonitoring:
            "Keystrokes are matched on this Mac and are never saved or sent anywhere."
        }
    }
}

// MARK: - Troubleshooting

private struct TroubleshootingList: View {
    let model: OnboardingModel
    /// The permission whose settings pane and reset the topics refer to; nil offers both.
    let kind: PermissionKind?
    let topics: [Trouble]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel("Troubleshooting")
                .padding(.bottom, Brand.Space.s8)
            ForEach(topics, id: \.self) { topic in
                let expanded = model.expandedTrouble == topic
                VStack(alignment: .leading, spacing: Brand.Space.s8) {
                    Button {
                        withAnimation(Motion.standard(reduceMotion: reduceMotion)) { model.toggle(topic) }
                    } label: {
                        HStack(spacing: Brand.Space.s8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .accessibilityHidden(true)
                            Text(title(topic))
                                .font(Brand.body(14, weight: 600))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Brand.textPrimary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")

                    if expanded {
                        detail(topic)
                            .padding(.leading, Brand.Space.s24)
                            .padding(.bottom, Brand.Space.s12)
                            .transition(.opacity)
                    }
                }
                if topic != topics.last {
                    Divider().overlay(Brand.borderSubtle)
                }
            }
        }
    }

    private func title(_ topic: Trouble) -> String {
        switch topic {
        case .notWorking: "I turned it on, but nothing happens"
        case .notListed: "I don't see OpenReaction in the list"
        case .afterUpdate: "It stopped working after an update"
        }
    }

    @ViewBuilder private func detail(_ topic: Trouble) -> some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            switch topic {
            case .notWorking:
                paragraph("macOS sometimes applies a new permission only to a fresh copy of the app. Relaunching takes a second and keeps your settings.")
                HStack(spacing: Brand.Space.s12) {
                    Button("Relaunch OpenReaction", action: model.relaunch)
                        .secondaryAction()
                        .disabled(!model.controller.canRelaunch)
                    errorText(model.controller.relaunchError)
                }
            case .notListed:
                paragraph("Click the + button under the list, choose OpenReaction and switch it on. If you're not sure where OpenReaction is, reveal it in Finder, then drag it into the list.")
                HStack(spacing: Brand.Space.s12) {
                    Button("Reveal app in Finder") { model.permissions.revealAppInFinder() }
                        .secondaryAction()
                    if let kind {
                        Button("Open System Settings") { model.request(kind) }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
            case .afterUpdate:
                paragraph("macOS ties permissions to the exact copy of an app. After an update the list can keep an old OpenReaction entry that looks switched on but no longer applies. Resetting removes only OpenReaction's entry so it can be added again.")
                HStack(spacing: Brand.Space.s12) {
                    ForEach(kind.map { [$0] } ?? PermissionKind.allCases, id: \.self) { kind in
                        Button(model.permissions.resetInProgress == kind ? "Resetting…" : "Reset \(kind.title)") { model.reset(kind) }
                            .secondaryAction()
                            .disabled(!model.permissions.canReset || model.permissions.resetInProgress != nil)
                    }
                }
                errorText(model.permissions.lastError)
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Brand.body(14))
            .lineSpacing(3)
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func errorText(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(Brand.body(13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Try it

private struct TryItStep: View {
    @Bindable var model: OnboardingModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controller: AppController { model.controller }
    private var permissions: PermissionMonitor { model.permissions }
    private var isStale: Bool { PermissionKind.allCases.contains { permissions.status($0) == .stale } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.Space.s24) {
                VStack(alignment: .leading, spacing: Brand.Space.s12) {
                    MonoLabel("Try it")
                    Text("Give it a go.")
                        .font(Brand.display(40))
                        .foregroundStyle(Brand.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Click the field and type :tada — choose 🎉 with Return, or finish the shortcode with a colon.")
                        .font(Brand.body(16))
                        .lineSpacing(4)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(Brand.Space.s32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var content: some View {
        if !controller.isEnabled {
            problemCard(
                title: "OpenReaction is paused.",
                detail: "Resume it to try a suggestion.",
                actionTitle: "Resume OpenReaction",
                action: resume
            )
        } else if isStale {
            problemCard(
                title: "macOS still has an old permission entry.",
                detail: "Both switches may look on, but they belong to an earlier copy of OpenReaction. Reset them, then switch OpenReaction on again."
            )
            TroubleshootingList(model: model, kind: nil, topics: [.afterUpdate, .notWorking])
                .onAppear { model.expandedTrouble = .afterUpdate }
        } else if controller.needsRelaunch {
            problemCard(
                title: "One more step.",
                detail: "macOS has allowed OpenReaction, but it isn't receiving keystrokes yet. A relaunch picks up the new permission.",
                actionTitle: controller.canRelaunch ? "Relaunch OpenReaction" : nil,
                action: relaunch
            )
            if let error = controller.relaunchError {
                Text(error).font(Brand.body(13)).foregroundStyle(Brand.textSecondary)
            }
            TroubleshootingList(model: model, kind: nil, topics: [.afterUpdate])
        } else if !controller.isTapRunning {
            HStack(spacing: Brand.Space.s8) {
                ProgressView().controlSize(.small)
                Text("Starting OpenReaction…").font(Brand.body(14)).foregroundStyle(Brand.textSecondary)
            }
        } else {
            practice
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s16) {
            TextField("Type :tada here", text: $model.practiceText)
                .textFieldStyle(.plain)
                .font(Brand.body(20))
                .padding(.horizontal, Brand.Space.s16)
                .frame(height: 56)
                .background(Brand.canvas, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                        .strokeBorder(fieldFocused ? Brand.accentSolid : Brand.borderControl, lineWidth: fieldFocused ? 2 : 1)
                }
                .focused($fieldFocused)
                .accessibilityLabel("Practice field")
                .accessibilityHint("Type colon, t, a, d, a to see emoji suggestions.")

            HStack(spacing: Brand.Space.s12) {
                if model.practiceSucceeded {
                    Label("It worked. That was the real picker.", systemImage: "checkmark.circle.fill")
                        .font(Brand.body(14, weight: 600))
                        .foregroundStyle(Brand.successSolid)
                        .symbolEffect(.bounce, value: reduceMotion ? false : model.practiceSucceeded)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                    Button("Continue", action: model.finishPractice)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text("Suggestions appear after two letters.")
                        .font(Brand.body(14))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer(minLength: 0)
                    Button("Skip", action: model.finishPractice)
                        .buttonStyle(LinkButtonStyle())
                }
            }
        }
        .padding(Brand.Space.s16)
        .cardSurface()
        .onAppear { fieldFocused = true }
    }

    private func resume() {
        controller.setEnabled(true)
    }

    private func relaunch() {
        model.relaunch()
    }

    private func problemCard(title: String, detail: String, actionTitle: String? = nil, action: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            Text(title)
                .font(Brand.body(16, weight: 600))
                .foregroundStyle(Brand.textPrimary)
            Text(detail)
                .font(Brand.body(14))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Brand.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Done

private struct DoneStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            MenuBarIllustration()
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                Text("You're all set.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("OpenReaction lives in the menu bar. Type a colon and a shortcode in any app.")
                    .font(Brand.body(16))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Can't see the icon? A full menu bar or the camera notch can hide it. Open OpenReaction again from Finder or Spotlight to reach its settings.")
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LoginItemToggle(loginItem: model.loginItem)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done", action: model.finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Brand.Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Open at login" switch reflecting the real `SMAppService` status.
struct LoginItemToggle: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Toggle(isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setOn($0) })) {
                Text("Open OpenReaction at login")
                    .font(Brand.body(14, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
            }
            .toggleStyle(.switch)
            .disabled(!loginItem.isAvailable)

            if !loginItem.isAvailable {
                note("Available once OpenReaction is installed as an app.")
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
            .font(Brand.body(13))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
