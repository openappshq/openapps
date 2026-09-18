import AppKit
import MacPaperCore
import SwiftUI

/// The menu-bar item: a click opens the panel under it (`PanelHost`), on
/// whichever display the item is on; a right click (or a Control-click)
/// opens a plain menu whose first item is **Show panel** with the shortcut
/// (design/products/macpaper.md, "Menu bar").
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let showSettings: () -> Void
    private let quit: () -> Void
    private let item: NSStatusItem
    private let menu = NSMenu()
    /// Shows or hides the panel under the item.
    var togglePanel: () -> Void = {}
    var panelIsShown: () -> Bool = { false }

    init(model: AppModel, preferences: Preferences, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.showSettings = showSettings
        self.quit = quit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = AppResources.menuBarImage()
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("macPaper")
            button.toolTip = "macPaper — click for the panel, right-click for the menu"
        }
        menu.delegate = self
    }

    /// The window the item lives in (the status bar's): a click there is
    /// never a click outside the panel.
    var buttonWindow: NSWindow? { item.button?.window }

    /// The item's frame in screen coordinates: where the column hangs
    /// from when opened from here.
    var buttonFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    /// The menu, shown by hand so the plain click keeps opening the panel:
    /// an item with a menu set shows it on every click, so the menu is
    /// attached for the one click that asks for it and detached after,
    /// which places it exactly as the system places a status item's menu.
    private func showMenu() {
        guard let button = item.button else { return }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let show = NSMenuItem(title: panelIsShown() ? "Hide panel" : "Show panel", action: #selector(togglePanelAction), keyEquivalent: "")
        show.target = self
        if let hotkey = preferences.hotkey {
            // The shortcut as set in Settings, shown the way every menu does.
            show.keyEquivalent = Hotkey.keyName(hotkey.keyCode)?.lowercased() ?? ""
            show.keyEquivalentModifierMask = Self.modifierMask(hotkey.modifiers)
        }
        menu.addItem(show)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        // An update asking for something (official builds; RELEASES.md,
        // "In-app updater"): "macPaper X.Y.Z available — Install",
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
        let quit = NSMenuItem(title: "Quit macPaper", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func togglePanelAction() { togglePanel() }
    @objc private func settingsAction() { showSettings() }
    @objc private func updateAction() {
        switch model.updates.hint() {
        case .ready: model.updates.restart()
        case .available: model.updates.install()
        case .downloading, nil: break
        }
    }
    @objc private func quitAction() { quit() }

    /// A hotkey's modifiers as a menu shows them.
    static func modifierMask(_ modifiers: Hotkey.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
