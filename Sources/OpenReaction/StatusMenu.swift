import AppKit
import Carbon.HIToolbox

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let controller: AppController
    private let showOnboarding: () -> Void
    /// Frontmost app when the menu opened; opening a status menu does not activate OpenReaction.
    private var frontmostApp: NSRunningApplication?

    init(controller: AppController, showOnboarding: @escaping () -> Void) {
        self.controller = controller
        self.showOnboarding = showOnboarding
        super.init()
        statusItem.button?.image = AppResources.menuBarImage()
        statusItem.button?.setAccessibilityLabel("OpenReaction")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateButton()
    }

    func updateButton() {
        statusItem.button?.appearsDisabled = !controller.isReady
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if controller.permissions.allGranted {
            menu.addItem(item(controller.isEnabled ? "Pause OpenReaction" : "Resume OpenReaction", #selector(toggleEnabled)))
        } else {
            menu.addItem(item("Set Up Permissions…", #selector(openOnboarding)))
        }

        if let app = frontmostApp, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? bundleID
            let toggle = item("Suggest in \(name)", #selector(toggleFrontmostApp))
            toggle.state = controller.exclusions.isExcluded(bundleID) ? .off : .on
            menu.addItem(toggle)
        }

        menu.addItem(.separator())
        if controller.permissions.allGranted {
            menu.addItem(item("Permissions…", #selector(openOnboarding)))
        }
        menu.addItem(item("About OpenReaction", #selector(showAbout)))
        menu.addItem(.separator())
        let quit = item("Quit OpenReaction", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var statusText: String {
        if !controller.permissions.allGranted { return "Needs permissions" }
        if !controller.isEnabled { return "Paused" }
        if IsSecureEventInputEnabled() { return "Paused while macOS protects typing" }
        return "On — type :shortcode: anywhere"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        controller.setEnabled(!controller.isEnabled)
    }

    @objc private func toggleFrontmostApp() {
        guard let bundleID = frontmostApp?.bundleIdentifier else { return }
        controller.setExcluded(!controller.exclusions.isExcluded(bundleID), bundleIdentifier: bundleID)
    }

    @objc private func openOnboarding() {
        showOnboarding()
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "Emoji suggestions for every text field.\nMIT License. Emoji data from GitHub gemoji (MIT).",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
