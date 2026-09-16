import AppKit
import MacPaperCore

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
            preferences: preferences, license: license, paths: .standard(), desktop: WorkspaceDesktopApplier(),
            exporter: PanelFileExporter(), imagePicker: PanelImagePicker(), displays: { ScreenCatalog.displays() }
        )
        self.model = model

        let statusItem = StatusItemController(model: model, showSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) })
        self.statusItem = statusItem
        let notch = NotchHost(
            model: model, preferences: preferences,
            onOpenPopover: { [weak statusItem] in statusItem?.open() },
            showSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )
        self.notch = notch
        statusItem.beforeOpen = { [weak notch] in notch?.closeAll() }

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

        #if OPENAPPS_LICENSING
        // The licensing ticket: the record store, the manager, the controller
        // bound to `licenseStatus`, and the login-item default decided once
        // storage says whether the install is fresh.
        #else
        // Licensing compiled out: no record store to wait for, so the
        // install is fresh when no earlier launch left preferences behind.
        // An update-test build never registers a login item.
        if !UpdateTesting.isCompiledIn {
            loginItem.applyDefaultIfNeeded(storageIsFresh: true)
        }
        #endif
        license.enterKey = { [weak self] in self?.showLicense(keyField: true) }
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
                return Diagnostics.text(model: self.model, preferences: self.preferences, loginItem: self.loginItem, hotkeys: hotkeys)
            }
        )
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

/// The update-test build variant (a later ticket's `scripts/update-e2e.sh`):
/// present in every build so the launch path can ask without `#if`.
nonisolated enum UpdateTesting {
    #if MACPAPER_UPDATE_TESTING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif
}
