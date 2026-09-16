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
        let quit = NSMenuItem(title: "Quit OpenNotes", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func newNoteAction() { newNote() }
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
