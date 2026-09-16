import AppKit
import OpenAppsLicensing
import OpenNotesCore
import SwiftUI

/// State of the setup guide. OpenNotes asks for nothing, so the step shown
/// is only the user's own progress: kept between launches, so "Show setup
/// guide" resumes where they left off, and only ever recorded forward.
@Observable
final class OnboardingModel {
    let loginItem: LoginItem
    let license: LicenseStatus
    let preferences: Preferences

    private(set) var step: GuideStep
    private(set) var isVisible = false
    @ObservationIgnored private let defaults: any FlagStore

    /// Opens Settings → License: from the trial pill on the welcome step
    /// and the tips.
    @ObservationIgnored var onOpenLicense: (() -> Void)?
    /// Opens Settings: from the files step and the tips.
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// Opens All Notes: from the tips.
    @ObservationIgnored var onOpenAllNotes: (() -> Void)?
    /// The files step's choice: On this Mac / iCloud Drive / Other
    /// folder… (`AppModel.setStorage`, the chooser for the last).
    @ObservationIgnored var onChooseStorage: ((StorageChoice) -> Void)?
    /// What the last switch copied, and whether the folder is missing,
    /// from the app's model; nothing without one (tests, the harness).
    @ObservationIgnored var storageNotice: () -> String? = { nil }
    @ObservationIgnored var folderIsMissing: () -> Bool = { false }
    @ObservationIgnored var onClose: (() -> Void)?

    init(loginItem: LoginItem, license: LicenseStatus, preferences: Preferences, defaults: any FlagStore = UserDefaults.standard) {
        self.loginItem = loginItem
        self.license = license
        self.preferences = preferences
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

    init(loginItem: LoginItem, license: LicenseStatus, preferences: Preferences, showSettings: @escaping () -> Void, showAllNotes: @escaping () -> Void, chooseStorage: @escaping (StorageChoice) -> Void = { _ in }, defaults: any FlagStore = UserDefaults.standard) {
        self.defaults = defaults
        model = OnboardingModel(loginItem: loginItem, license: license, preferences: preferences, defaults: defaults)
        super.init()
        model.onClose = { [weak self] in self?.window?.close() }
        model.onOpenLicense = { [license] in license.openLicense() }
        model.onOpenSettings = showSettings
        model.onOpenAllNotes = showAllNotes
        model.onChooseStorage = chooseStorage
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
            window.title = "Set Up OpenNotes"
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
                loginItem: loginItem, license: licenseStatus, preferences: preferences,
                showSettings: { [weak self] in self?.showSettings() },
                showAllNotes: { [weak self] in self?.showAllNotes() },
                chooseStorage: { [weak self] in self?.chooseStorage($0) }
            )
            onboarding?.model.storageNotice = { [weak self] in self?.model.storageNotice }
            onboarding?.model.folderIsMissing = { [weak self] in self?.model.store.folderIsMissing ?? false }
        }
        onboarding?.show()
    }

    /// The guide's storage choice: the same rule as Settings (the license
    /// asked at the click, and again when the chooser returns).
    private func chooseStorage(_ choice: StorageChoice) {
        guard choice == .other else {
            model.setStorage(choice)
            return
        }
        guard model.mayChangeFolder() else { return }
        if let url = FolderChooser.present(current: preferences.folder) { model.setFolder(url) }
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

extension Motion {
    /// The guide's step change: a little longer than a control's.
    static func expressive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Brand.Motion.fast) : .easeOut(duration: Brand.Motion.expressive)
    }
}
