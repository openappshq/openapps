import AppKit
import OpenNotesCore

/// The menu-bar item: a template sticky and a plain menu (design/products/
/// opennotes.md, "Menu bar"). No popover: the deck is the surface.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let item: NSStatusItem
    private let menu = NSMenu()
    var newNote: () -> Void = {}
    var showAllNotes: () -> Void = {}
    var showSettings: () -> Void = {}
    /// Settings → License, from the license line.
    var showLicense: () -> Void = {}
    var toggleDeck: () -> Void = {}
    var deckIsShown: () -> Bool = { true }
    var quit: () -> Void = {}

    init(model: AppModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = AppResources.menuBarImage()
            button.setAccessibilityLabel("OpenNotes")
            button.toolTip = "OpenNotes"
        }
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The license, asked as the menu opens: the trial's remaining time
        // or why the notes are read-only (LicenseBadge); nothing while
        // simply licensed or without licensing. Opens Settings → License.
        if let badge = model.license.badge() {
            let line = NSMenuItem(title: badge.text, action: #selector(licenseAction), keyEquivalent: "")
            line.target = self
            if badge.tone == .attention {
                line.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            }
            menu.addItem(line)
            menu.addItem(.separator())
        }
        let new = NSMenuItem(title: model.readOnly ? "New Note (read-only)" : "New Note", action: #selector(newNoteAction), keyEquivalent: "")
        new.target = self
        new.isEnabled = !model.readOnly
        if let hotkey = preferences.hotkey {
            new.keyEquivalent = Hotkey.keyName(hotkey.keyCode)?.lowercased() ?? ""
            new.keyEquivalentModifierMask = Self.modifierMask(hotkey.modifiers)
        }
        menu.addItem(new)
        let deck = NSMenuItem(title: deckIsShown() ? "Hide Deck" : "Show Deck", action: #selector(toggleDeckAction), keyEquivalent: "")
        deck.target = self
        menu.addItem(deck)
        menu.addItem(.separator())
        let all = NSMenuItem(title: "All Notes…", action: #selector(allNotesAction), keyEquivalent: "l")
        all.keyEquivalentModifierMask = [.option, .command]
        all.target = self
        menu.addItem(all)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        // An update asking for something (official builds; RELEASES.md,
        // "In-app updater"): "OpenNotes X.Y.Z available — Install",
        // "Downloading…", "Update ready — Restart". Nothing otherwise.
        if let hint = model.updates.hint() {
            let title = [UpdateCopy.line(for: hint), UpdateCopy.action(for: hint)].compactMap { $0 }.joined(separator: " — ")
            let update = NSMenuItem(title: title, action: #selector(updateAction), keyEquivalent: "")
            update.target = self
            update.isEnabled = UpdateCopy.action(for: hint) != nil
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit OpenNotes", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func newNoteAction() { newNote() }
    @objc private func licenseAction() { showLicense() }
    @objc private func updateAction() {
        switch model.updates.hint() {
        case .ready: model.updates.restart()
        case .available: model.updates.install()
        case .downloading, nil: break
        }
    }
    @objc private func toggleDeckAction() { toggleDeck() }
    @objc private func allNotesAction() { showAllNotes() }
    @objc private func settingsAction() { showSettings() }
    @objc private func quitAction() { quit() }

    private static func modifierMask(_ modifiers: Hotkey.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
