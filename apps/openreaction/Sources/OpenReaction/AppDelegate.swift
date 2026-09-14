import AppKit
import OpenReactionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var statusMenu: StatusMenuController?
    private var onboarding: OnboardingWindowController?
    private var settings: SettingsWindowController?
    private var loginItem: LoginItem?
    private var preview: PreviewHarness?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppResources.registerFonts()
        if Bundle.main.bundleIdentifier == nil, let icon = AppResources.appIcon() {
            // Running unbundled via `swift run`.
            NSApp.applicationIconImage = icon
        }

        let emojiData: EmojiCatalogLoader.Result
        do {
            emojiData = try EmojiCatalogLoader.load()
        } catch {
            let alert = NSAlert()
            alert.messageText = "OpenReaction can't load its emoji list"
            alert.informativeText = "Reinstall OpenReaction. (\(error.localizedDescription))"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let provider = EmojiSuggestionProvider(catalog: emojiData.catalog)
        if CommandLine.arguments.contains("--preview-picker") {
            preview = PreviewHarness(provider: provider, dataSourceSummary: emojiData.summary)
            return
        }

        installMainMenu()

        let controller = AppController(provider: provider, dataSourceSummary: emojiData.summary)
        let loginItem = LoginItem()
        let statusMenu = StatusMenuController(
            controller: controller,
            showOnboarding: { [weak self] in self?.onboarding?.show() },
            showSettings: { [weak self] in self?.settings?.show() }
        )
        let onboarding = OnboardingWindowController(controller: controller, loginItem: loginItem) { [weak statusMenu] in
            statusMenu?.buttonScreenFrame
        }
        let settings = SettingsWindowController(controller: controller, loginItem: loginItem) { [weak onboarding] in
            onboarding?.show()
        }
        controller.onStateChange = { [weak statusMenu] in statusMenu?.updateButton() }
        self.controller = controller
        self.loginItem = loginItem
        self.statusMenu = statusMenu
        self.onboarding = onboarding
        self.settings = settings

        // Reads permissions and tries the tap once, so the launch decision
        // below sees current state.
        controller.start()
        if OnboardingWindowController.shouldShowOnLaunch(permissions: controller.permissions) {
            onboarding.show()
        }
    }

    /// Opening OpenReaction again from Finder or Spotlight while it runs. The
    /// status item can be hidden by the notch or a crowded menu bar, so this
    /// must always lead somewhere: setup while it is incomplete, else settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let controller else { return true }
        if !controller.permissions.snapshot.isComplete {
            onboarding?.show()
        } else {
            settings?.show()
        }
        return false
    }

    // MARK: - Main menu

    /// Never visible for a menu-bar app, but it is what makes Command-W,
    /// Command-comma, Command-Q and the editing shortcuts work in our windows.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OpenReaction", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenReaction", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "OpenReaction")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "Window")

        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        settings?.show()
    }

    @objc private func showAbout() {
        guard let controller else { return }
        Diagnostics.showAboutPanel(controller: controller)
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
