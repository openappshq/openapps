import AppKit
import OpenNotesCore
import SwiftUI

/// Owns the long-lived objects: the model, preferences, the login item,
/// the status item, the decks, the hotkey, All Notes and Settings.
/// Menu-bar only: no Dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var preferences: Preferences!
    private(set) var model: AppModel!
    private(set) var loginItem: LoginItem!
    private var statusItem: StatusItemController?
    private var deck: DeckHost?
    private var hotkeys: HotkeyCenter?
    private var settingsWindow: SettingsWindowController?
    private var allNotesWindow: AllNotesWindowController?
    #if OPENAPPS_LICENSING
    // The parity ticket: the record store, the manager and the controller
    // bound to the model's `readOnly` (LICENSING.md), the trial pill, the
    // License section in Settings, the first-run guide.
    #endif
    #if OPENAPPS_OFFICIAL
    // The parity ticket: the shared updater (RELEASES.md), created before
    // this launch writes any preferences.
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
        let model = AppModel(preferences: preferences)
        self.model = model
        model.start()

        let statusItem = StatusItemController(model: model, preferences: preferences)
        self.statusItem = statusItem
        statusItem.newNote = { [weak self] in self?.deck?.hotkey() }
        statusItem.showAllNotes = { [weak self] in self?.showAllNotes() }
        statusItem.showSettings = { [weak self] in self?.showSettings() }
        statusItem.toggleDeck = { [weak self] in self?.toggleDeck() }
        statusItem.deckIsShown = { [weak self] in self?.deck != nil }
        statusItem.quit = { NSApp.terminate(nil) }

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

        // No record store to wait for in this build: the install is fresh
        // when no earlier launch left preferences behind. The parity ticket
        // makes storage the judge (LICENSING.md) and adds the setup guide.
        // An update-test build never registers a login item.
        if !UpdateTesting.isCompiledIn {
            loginItem.applyDefaultIfNeeded(storageIsFresh: true)
        }
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
        return .terminateNow
    }

    /// The hotkey's Carbon handler goes with the app.
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.removeHandler()
    }

    func showSettings() {
        settings().show()
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

/// The update-test build variant (`scripts/update-e2e.sh`, the parity
/// ticket): present in every build so the launch path can ask without `#if`.
nonisolated enum UpdateTesting {
    #if OPENNOTES_UPDATE_TESTING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif
}
