import AppKit
import OpenReactionCore
import SwiftUI

/// Troubleshooting topics offered beside the permission steps.
enum Trouble: Hashable {
    /// Switched on, but suggestions still do not appear.
    case notWorking
    /// OpenReaction is missing from the System Settings list.
    case notListed
    /// An old entry from an earlier build no longer applies.
    case afterUpdate
}

/// State of the onboarding window. The step shown is derived from the
/// permission flow; this model only adds the user's own progress (started,
/// practice finished) and the short success beat before advancing.
@MainActor
@Observable
final class OnboardingModel {
    let controller: AppController
    let permissions: PermissionMonitor
    let loginItem: LoginItem

    private(set) var displayedStep = OnboardingStep.welcome
    /// Permission just granted; its step stays on screen briefly to show it.
    private(set) var celebrating: PermissionKind?
    private(set) var isVisible = false
    private(set) var practiceSucceeded = false
    var practiceText = "" {
        didSet { checkPractice() }
    }
    var expandedTrouble: Trouble?
    var showHow: Set<PermissionKind> = []

    private(set) var hasStarted: Bool {
        didSet { UserDefaults.standard.set(hasStarted, forKey: Keys.started) }
    }
    private(set) var practiceFinished: Bool {
        didSet { UserDefaults.standard.set(practiceFinished, forKey: Keys.practiceFinished) }
    }

    @ObservationIgnored var onRequest: ((PermissionKind) -> Void)?
    /// Opens Settings (License), for the practice step when the license
    /// keeps the picker off.
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onStepChange: ((OnboardingStep) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?

    enum Keys {
        static let started = "onboarding.started"
        static let practiceFinished = "onboarding.practiceFinished"
        static let shown = "onboarding.shown"
        static let resumeAfterRelaunch = "onboarding.resumeAfterRelaunch"
    }

    init(controller: AppController, loginItem: LoginItem) {
        self.controller = controller
        self.permissions = controller.permissions
        self.loginItem = loginItem
        hasStarted = UserDefaults.standard.bool(forKey: Keys.started)
        practiceFinished = UserDefaults.standard.bool(forKey: Keys.practiceFinished)
    }

    var derivedStep: OnboardingStep {
        permissions.onboardingStep(hasStarted: hasStarted, practiceFinished: practiceFinished)
    }

    // MARK: - Visibility

    func didShow() {
        isVisible = true
        advanceTask?.cancel()
        celebrating = nil
        setStep(derivedStep, animated: false)
    }

    func didHide() {
        isVisible = false
        advanceTask?.cancel()
        celebrating = nil
    }

    // MARK: - Actions

    func getStarted() {
        hasStarted = true
        sync()
    }

    func request(_ kind: PermissionKind) {
        permissions.request(kind)
        showHow.insert(kind)
        onRequest?(kind)
    }

    func reset(_ kind: PermissionKind) {
        Task { await permissions.reset(kind) }
    }

    func relaunch() {
        UserDefaults.standard.set(true, forKey: Keys.resumeAfterRelaunch)
        controller.relaunch()
    }

    func finishPractice() {
        practiceFinished = true
        sync()
    }

    func finish() {
        onClose?()
    }

    func toggle(_ trouble: Trouble) {
        expandedTrouble = expandedTrouble == trouble ? nil : trouble
    }

    // MARK: - Step changes

    /// Moves to the derived step. Leaving a permission step because it was
    /// granted first holds the step for a moment so the success state is seen
    /// (and announced); going backwards happens immediately.
    func sync() {
        guard isVisible, celebrating == nil else { return }
        let target = derivedStep
        guard target != displayedStep else { return }
        if let kind = displayedStep.permission, target > displayedStep, permissions.snapshot.reportedGranted.contains(kind) {
            celebrating = kind
            announce("\(kind.title) allowed.")
            let hold: Duration = Motion.reduceMotion ? .milliseconds(500) : .milliseconds(900)
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: hold)
                guard let self, !Task.isCancelled else { return }
                self.celebrating = nil
                self.setStep(self.derivedStep, animated: true)
            }
            return
        }
        setStep(target, animated: true)
    }

    private func setStep(_ step: OnboardingStep, animated: Bool) {
        guard step != displayedStep else { return }
        let apply = {
            self.displayedStep = step
            if let kind = step.permission {
                self.expandedTrouble = self.permissions.status(kind) == .stale ? .afterUpdate : nil
            } else {
                self.expandedTrouble = nil
            }
        }
        if animated {
            withAnimation(Motion.expressive(reduceMotion: Motion.reduceMotion), apply)
        } else {
            apply()
        }
        if step == .done { loginItem.refresh() }
        onStepChange?(step)
    }

    private func checkPractice() {
        guard !practiceSucceeded, practiceText.contains("🎉") else { return }
        withAnimation(Motion.expressive(reduceMotion: Motion.reduceMotion)) {
            practiceSucceeded = true
        }
        announce("It worked. OpenReaction inserted the party popper emoji.")
    }
}

/// The single onboarding window. Menu-bar apps never show in the Dock, so the
/// window is brought forward with `NSApp.activate()`.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private let guide: GuidePanelController
    private let menuBarHint = MenuBarHintController()
    private let statusItemFrame: () -> CGRect?
    private var window: NSWindow?

    init(controller: AppController, loginItem: LoginItem, statusItemFrame: @escaping () -> CGRect?) {
        model = OnboardingModel(controller: controller, loginItem: loginItem)
        guide = GuidePanelController(permissions: controller.permissions)
        self.statusItemFrame = statusItemFrame
        super.init()
        model.onClose = { [weak self] in self?.window?.close() }
        model.onRequest = { [weak self] kind in self?.guide.show(kind) }
        model.onStepChange = { [weak self] step in self?.stepChanged(step) }
        guide.onNotListed = { [weak self] _ in
            guard let self else { return }
            self.show()
            self.model.expandedTrouble = .notListed
        }
    }

    /// First launch, a missing or broken permission, or a relaunch started
    /// from onboarding. Consumes the relaunch marker.
    static func shouldShowOnLaunch(permissions: PermissionMonitor) -> Bool {
        let defaults = UserDefaults.standard
        let resume = defaults.bool(forKey: OnboardingModel.Keys.resumeAfterRelaunch)
        defaults.removeObject(forKey: OnboardingModel.Keys.resumeAfterRelaunch)
        return resume || !defaults.bool(forKey: OnboardingModel.Keys.shown) || !permissions.snapshot.isComplete
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let hostingView = NSHostingView(rootView: OnboardingView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width, height: OnboardingView.size.height),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Set Up OpenReaction"
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.contentView = hostingView
            window.delegate = self
            window.center()
            self.window = window
        }
        UserDefaults.standard.set(true, forKey: OnboardingModel.Keys.shown)
        model.permissions.setFastPolling(true, reason: "onboarding")
        model.didShow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.didHide()
        model.permissions.setFastPolling(false, reason: "onboarding")
        menuBarHint.hide()
    }

    private func stepChanged(_ step: OnboardingStep) {
        if step == .done, isVisible || model.isVisible, let frame = statusItemFrame() {
            menuBarHint.show(below: frame)
        } else {
            menuBarHint.hide()
        }
    }
}
