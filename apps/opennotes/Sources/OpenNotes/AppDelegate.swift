import AppKit
import OpenNotesCore
import SwiftUI

/// Owns the long-lived objects: the model, preferences, the login item,
/// the status item, the decks, the hotkey, All Notes, Settings, the setup
/// guide, licensing and the updater. Menu-bar only: no Dock icon, no main
/// window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var preferences: Preferences!
    private(set) var model: AppModel!
    private(set) var loginItem: LoginItem!
    private(set) var licenseStatus: LicenseStatus!
    private var statusItem: StatusItemController?
    private var deck: DeckHost?
    private var hotkeys: HotkeyCenter?
    private var settingsWindow: SettingsWindowController?
    private var allNotesWindow: AllNotesWindowController?
    var onboarding: OnboardingWindowController?
    #if OPENAPPS_LICENSING
    /// The record store, the manager and the controller bound to
    /// `licenseStatus` (Licensing/LicensingLaunch.swift).
    var licenseController: LicenseController?
    #endif
    #if OPENAPPS_OFFICIAL
    /// The shared updater (Updates/UpdatesLaunch.swift), created before
    /// this launch writes any preferences.
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
        let model = AppModel(preferences: preferences, license: license)
        self.model = model
        // Official builds: the updater, before this launch writes any
        // preferences (Updates/UpdatesLaunch.swift).
        startUpdates()
        model.start()

        let statusItem = StatusItemController(model: model, preferences: preferences)
        self.statusItem = statusItem
        statusItem.newNote = { [weak self] in self?.deck?.hotkey() }
        statusItem.showAllNotes = { [weak self] in self?.showAllNotes() }
        statusItem.showSettings = { [weak self] in self?.showSettings() }
        statusItem.showLicense = { [weak self] in self?.showLicense() }
        statusItem.toggleDeck = { [weak self] in self?.toggleDeck() }
        statusItem.deckIsShown = { [weak self] in self?.deck != nil }
        statusItem.quit = { NSApp.terminate(nil) }
        registerURLHandler()

        deck = DeckHost(model: model, preferences: preferences, showAllNotes: { [weak self] in self?.showAllNotes() })

        let hotkeys = HotkeyCenter()
        self.hotkeys = hotkeys
        hotkeys.onPressed = { [weak self] in
            guard let self else { return }
            if self.deck == nil { self.toggleDeck() }
            self.deck?.hotkey()
        }
        hotkeys.register(preferences.hotkey)
        observeChanges({ [preferences] in _ = preferences.hotkey }, onChange: { [weak self, preferences] in self?.hotkeys?.register(preferences.hotkey) })

        // Licensing (Licensing/LicensingLaunch.swift): in an official build
        // the record store, the manager and the controller bound to
        // `licenseStatus`, and the fresh-install defaults decided once
        // storage says whether the install is fresh; from source, everything
        // on and the defaults decided now. Then the updater's schedule and,
        // once, the setup guide.
        startLicensing()
        startUpdaterSchedule()
        showGuideOnFirstLaunchIfNeeded()
    }

    /// Quit flushes every open and pending note first. If any cannot be
    /// written the quit is held: the alert offers Try Again (the flush
    /// runs again) or Keep Editing (the quit is cancelled; the text stays
    /// in the app, dirty, retried every few seconds). Nothing is ever
    /// discarded on the way out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        deck?.saveAll()
        var problems = model.flush()
        while !problems.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = problems.count == 1 ? "A note couldn’t be saved" : "\(problems.count) notes couldn’t be saved"
            alert.informativeText = problems.sorted { $0.key < $1.key }.map { "\($0.key.fileName): \($0.value)" }.joined(separator: "\n")
                + "\n\nThe text is still in OpenNotes. Try again once the folder is back, or keep editing and quit later."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Keep Editing")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                problems = model.flush()
            } else {
                return .terminateCancel
            }
        }
        // Then the license's last save and the updater's staged install
        // (Licensing/LicensingLaunch.swift); nothing in a source build.
        return finishTerminate()
    }

    /// The hotkey's Carbon handler goes with the app.
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.removeHandler()
    }

    func showSettings() {
        settings().show()
    }

    func showLicense(keyField: Bool = false) {
        settings().showLicense(keyField: keyField)
    }

    func showAllNotes() {
        if allNotesWindow == nil {
            allNotesWindow = AllNotesWindowController(model: model) { [weak self] id in self?.deck?.open(id) }
        }
        allNotesWindow?.show()
    }

    /// Show Deck / Hide Deck: hidden decks save their open note first.
    func toggleDeck() {
        if let deck {
            deck.saveAll()
            model.flush()
            self.deck = nil
        } else {
            deck = DeckHost(model: model, preferences: preferences, showAllNotes: { [weak self] in self?.showAllNotes() })
        }
    }

    private func settings() -> SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let controller = SettingsWindowController(
            model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys ?? HotkeyCenter(),
            diagnostics: { [weak self] in
                guard let self, let hotkeys = self.hotkeys else { return "" }
                return Diagnostics.text(model: self.model, preferences: self.preferences, loginItem: self.loginItem, hotkeys: hotkeys, deck: self.deck)
            }
        )
        // License and Updates before About (Licensing/LicensingLaunch.swift),
        // the guide from About, the trial pill in the title bar.
        controller.extraSections = licensingSettingsSections(navigation: controller.navigation)
        controller.showGuide = { [weak self] in self?.showGuide() }
        controller.titleBarBadge = { [weak self] in self?.licenseStatus.badge() }
        settingsWindow = controller
        return controller
    }

    /// Opening OpenNotes again from Finder or Spotlight while it runs: the
    /// status item can be hidden by a crowded menu bar, so this opens All
    /// Notes.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAllNotes()
        return false
    }
}

/// The update-test build variant (`scripts/update-e2e.sh`): present in every
/// build so the launch path can ask without `#if`; its hooks are in
/// Updates/UpdateTesting.swift.
nonisolated enum UpdateTesting {
    #if OPENNOTES_UPDATE_TESTING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif
}
