import AppKit
import MacPaperCore
import SwiftUI

/// Owns the long-lived objects: the model, preferences, the login item, the
/// status item and popover, the notch panels, the hotkey, the shuffle
/// engine and the settings window. Menu-bar only: no Dock icon, no main
/// window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var preferences: Preferences!
    private(set) var model: AppModel!
    private(set) var loginItem: LoginItem!
    private(set) var licenseStatus: LicenseStatus!
    private var statusItem: StatusItemController?
    private var notch: NotchHost?
    private var hotkeys: HotkeyCenter?
    private var shuffle: ShuffleEngine?
    private var settingsWindow: SettingsWindowController?
    private(set) var keeper: DesktopKeeper?
    private var theme: ThemeWatcher?
    private var clock: ClockController?
    /// Filled by the licensing wiring before the first panel or popover
    /// shows: the trial pill above the preview.
    var panelHeader: (() -> AnyView)?
    var onboarding: OnboardingWindowController?
    #if OPENAPPS_LICENSING
    var licenseController: LicenseController?
    #endif
    #if OPENAPPS_OFFICIAL
    var updates: Updates?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = AppResources.appIcon() { NSApp.applicationIconImage = icon }
        AppResources.registerFonts()

        // Created first, before this launch writes any preferences, so the
        // fresh-install default reads the launch's.
        let loginItem = LoginItem()
        self.loginItem = loginItem
        let preferences = Preferences()
        self.preferences = preferences
        let license = LicenseStatus()
        licenseStatus = license
        let model = AppModel(
            preferences: preferences, license: license, paths: .standard(appID: UpdateTesting.isCompiledIn ? "macpaper-updatetest" : "macpaper"),
            desktop: WorkspaceDesktopApplier(),
            exporter: PanelFileExporter(), imagePicker: PanelImagePicker(), displays: { ScreenCatalog.displays() }
        )
        self.model = model
        // Official builds: the updater, before this launch writes any
        // preferences (UpdatesLaunch.swift).
        startUpdates()

        let statusItem = StatusItemController(model: model, showSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) })
        self.statusItem = statusItem
        statusItem.header = { [weak self] in self?.panelHeader?() ?? AnyView(EmptyView()) }
        let notch = NotchHost(
            model: model, preferences: preferences,
            onOpenPopover: { [weak statusItem] in statusItem?.open() },
            showSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )
        notch.header = { [weak self] in self?.panelHeader?() ?? AnyView(EmptyView()) }
        self.notch = notch
        statusItem.beforeOpen = { [weak notch] in notch?.closeAll() }

        // Apply, finished: the pin, the theme swap, shared links, the clock.
        keeper = DesktopKeeper(model: model, preferences: preferences, desktop: WorkspaceDesktopApplier())
        theme = ThemeWatcher { [weak model] in model?.themeChanged() }
        registerURLHandler()
        clock = ClockController(model: model, preferences: preferences)

        let hotkeys = HotkeyCenter()
        self.hotkeys = hotkeys
        hotkeys.onPressed = { [weak self] in
            guard let self else { return }
            if self.statusItem?.isShown == true {
                self.statusItem?.close()
            } else {
                self.notch?.toggleFromHotkey()
            }
        }
        hotkeys.register(preferences.hotkey)
        observeChanges({ [preferences] in _ = preferences.hotkey }, onChange: { [weak self, preferences] in self?.hotkeys?.register(preferences.hotkey) })

        shuffle = ShuffleEngine(model: model, preferences: preferences)

        // Licensing (LicensingLaunch.swift): in an official build the record
        // store, the manager and the controller bound to `licenseStatus`, and
        // the fresh-install defaults decided once storage says whether the
        // install is fresh; from source, everything on and the defaults
        // decided now. Then the updater's schedule and, once, the setup guide.
        startLicensing()
        startUpdaterSchedule()
        showGuideOnFirstLaunchIfNeeded()
    }

    /// The hotkey's Carbon handler is removed with the app; the pin has
    /// nothing to do at quit (the applied files stay).
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.removeHandler()
    }

    func showSettings() {
        settings().show()
    }

    func showLicense(keyField: Bool = false) {
        settings().showLicense(keyField: keyField)
    }

    private func settings() -> SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let controller = SettingsWindowController(
            model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys ?? HotkeyCenter(),
            diagnostics: { [weak self] in
                guard let self, let hotkeys = self.hotkeys else { return "" }
                return Diagnostics.text(model: self.model, preferences: self.preferences, loginItem: self.loginItem, hotkeys: hotkeys, keeper: self.keeper)
            }
        )
        // License and Updates before About (LicensingLaunch.swift), the
        // guide from About, the trial pill in the title bar.
        controller.extraSections = licensingSettingsSections(navigation: controller.navigation)
        controller.showGuide = { [weak self] in self?.showGuide() }
        controller.titleBarBadge = { [weak self] in self?.licenseStatus.badge() }
        settingsWindow = controller
        return controller
    }

    /// Opening macPaper again from Finder or Spotlight while it runs: the
    /// status item can be hidden by a crowded menu bar, so this always
    /// leads to Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}

/// The update-test build variant (`scripts/update-e2e.sh`): present in every
/// build so the launch path can ask without `#if`; its hooks are in
/// Updates/UpdateTesting.swift.
nonisolated enum UpdateTesting {
    #if MACPAPER_UPDATE_TESTING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif
}
