import AppKit
import MacPaperCore
import OpenAppsLicensing
import SwiftUI

/// State of the setup guide. macPaper asks for nothing, so the step shown
/// is only the user's own progress: kept between launches, so "Show setup
/// guide" resumes where they left off, and only ever recorded forward.
@Observable
final class OnboardingModel {
    let loginItem: LoginItem
    let license: LicenseStatus

    private(set) var step: GuideStep
    private(set) var isVisible = false
    @ObservationIgnored private let defaults: any FlagStore

    /// Opens Settings → License: from the trial pill on the welcome step
    /// and the tips.
    @ObservationIgnored var onOpenLicense: (() -> Void)?
    /// Opens Settings: from the tips.
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    init(loginItem: LoginItem, license: LicenseStatus, defaults: any FlagStore = UserDefaults.standard) {
        self.loginItem = loginItem
        self.license = license
        self.defaults = defaults
        step = OnboardingLaunch.resumeStep(store: defaults)
    }

    /// The trial's remaining time or the license's short reason, in
    /// official builds; nil while licensed or without licensing.
    var licenseBadge: LicenseBadge.Label? { license.badge() }

    /// What the welcome step says about the trial: only what the license
    /// reports now. Nothing without licensing.
    var licenseLine: String? { GuideCopy.licenseLine(state: license.state()) }

    // MARK: - Visibility

    func didShow() {
        isVisible = true
        setStep(OnboardingLaunch.resumeStep(store: defaults), animated: false)
    }

    func didHide() {
        isVisible = false
    }

    // MARK: - Actions

    func getStarted() {
        advance()
    }

    func advance() {
        guard let next = step.next else { return }
        setStep(next, animated: true)
    }

    func back() {
        guard let previous = step.previous else { return }
        setStep(previous, animated: true)
    }

    func finish() {
        onClose?()
    }

    /// Closes the window at any step. Progress is kept, so "Show setup
    /// guide" resumes where the user left off.
    func skip() {
        onClose?()
    }

    private func setStep(_ step: GuideStep, animated: Bool) {
        OnboardingLaunch.markReached(step, store: defaults)
        guard step != self.step else { return }
        if animated {
            withAnimation(Motion.expressive(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                self.step = step
            }
        } else {
            self.step = step
        }
        if step == .loginItem { loginItem.refresh() }
    }
}

/// The single setup window. Menu-bar apps never show in the Dock, so the
/// window is brought forward with `NSApp.activate()`.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private let defaults: any FlagStore
    private var window: NSWindow?

    init(loginItem: LoginItem, license: LicenseStatus, showSettings: @escaping () -> Void, defaults: any FlagStore = UserDefaults.standard) {
        self.defaults = defaults
        model = OnboardingModel(loginItem: loginItem, license: license, defaults: defaults)
        super.init()
        model.onClose = { [weak self] in self?.window?.close() }
        model.onOpenLicense = { [license] in license.openLicense() }
        model.onOpenSettings = showSettings
    }

    func show() {
        if window == nil {
            let hostingView = NSHostingView(rootView: OnboardingView(model: model))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Set Up macPaper"
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.contentView = hostingView
            window.delegate = self
            window.center()
            self.window = window
        }
        OnboardingLaunch.markShown(store: defaults)
        model.didShow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.didHide()
    }
}

extension AppDelegate {
    /// The setup guide, from Settings or on the first launch.
    func showGuide() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                loginItem: loginItem, license: licenseStatus, showSettings: { [weak self] in self?.showSettings() }
            )
        }
        onboarding?.show()
    }

    /// Once, on the first launch of the packaged app. `swift run` builds
    /// skip it so a development loop never opens a window; update-test
    /// builds never open one either.
    func showGuideOnFirstLaunchIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app", !UpdateTesting.isCompiledIn,
              OnboardingLaunch.shouldShow(store: UserDefaults.standard) else { return }
        showGuide()
    }
}
