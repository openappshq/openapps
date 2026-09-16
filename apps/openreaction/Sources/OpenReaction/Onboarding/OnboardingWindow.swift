import AppKit
import OpenAppsLicensing
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
        didSet { defaults.set(hasStarted, forKey: Keys.started) }
    }
    private(set) var practiceFinished: Bool {
        didSet { defaults.set(practiceFinished, forKey: Keys.practiceFinished) }
    }
    /// `--preview-setup` pins a step regardless of permissions.
    var previewStep: OnboardingStep? {
        didSet { sync() }
    }
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored var onRequest: ((PermissionKind) -> Void)?
    /// Opens Settings → License: from the trial pill on the welcome step,
    /// and from the practice step when the license keeps the picker off.
    @ObservationIgnored var onOpenLicense: (() -> Void)?
    @ObservationIgnored var onStepChange: ((OnboardingStep) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?

    enum Keys {
        static let started = "onboarding.started"
        static let practiceFinished = "onboarding.practiceFinished"
    }

    /// The trial's remaining time or the license's short reason, in
    /// official builds; nil while licensed or without licensing.
    var licenseBadge: LicenseBadge.Label? { controller.licenseBadge }

    init(controller: AppController, loginItem: LoginItem, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.permissions = controller.permissions
        self.loginItem = loginItem
        self.defaults = defaults
        hasStarted = defaults.bool(forKey: Keys.started)
        practiceFinished = defaults.bool(forKey: Keys.practiceFinished)
    }

    var derivedStep: OnboardingStep {
        previewStep ?? permissions.onboardingStep(hasStarted: hasStarted, practiceFinished: practiceFinished)
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

    /// Granting in System Settings can end with macOS quitting and reopening
    /// the app; the marker brings the window back in that new process.
    func request(_ kind: PermissionKind) {
        OnboardingLaunch.markAwaitingPermission(store: defaults)
        permissions.request(kind)
        showHow.insert(kind)
        onRequest?(kind)
    }

    /// A successful reset ends by asking again, so it is marked like
    /// `request` — unless the user closed the window while it ran.
    func reset(_ kind: PermissionKind) {
        Task {
            guard await permissions.reset(kind), isVisible else { return }
            OnboardingLaunch.markAwaitingPermission(store: defaults)
        }
    }

    func relaunch() {
        OnboardingLaunch.markResumeAfterRelaunch(store: defaults)
        controller.relaunch()
    }

    func finishPractice() {
        practiceFinished = true
        sync()
    }

    func finish() {
        didDismiss()
        onClose?()
    }

    /// Closes the window at any step. Progress is kept, so "Show setup
    /// guide" resumes where the user left off.
    func skip() {
        didDismiss()
        onClose?()
    }

    /// The user closed the window themselves (skip, finish, the close
    /// button): it will not come back on its own until it asks for a
    /// permission again. Only these paths call it — a quit closes windows
    /// too, but that is not a dismissal, and the marker must survive
    /// macOS's "Quit & Reopen".
    func didDismiss() {
        OnboardingLaunch.clearAwaitingPermission(store: defaults)
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
    private let defaults: UserDefaults
    private var window: NSWindow?

    init(controller: AppController, loginItem: LoginItem, defaults: UserDefaults = .standard, statusItemFrame: @escaping () -> CGRect?) {
        self.defaults = defaults
        model = OnboardingModel(controller: controller, loginItem: loginItem, defaults: defaults)
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

    /// The first launch, a relaunch started from onboarding, or macOS
    /// reopening the app after a permission the window asked for was
    /// granted. Consumes the markers. An unfinished setup the user closed
    /// does not reopen the window by itself: the status item's badge and
    /// "Finish Setup…" carry it.
    static func shouldShowOnLaunch() -> Bool {
        OnboardingLaunch.shouldShow(store: UserDefaults.standard)
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
        OnboardingLaunch.markShown(store: defaults)
        model.permissions.setFastPolling(true, reason: "onboarding")
        model.didShow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The close button (and ⌘W) asks first; termination closes windows
    /// without asking, so only the user's own close lands here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.didDismiss()
        return true
    }

    /// Reached by every close, a quit's included: nothing here may decide
    /// whether the window comes back.
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
