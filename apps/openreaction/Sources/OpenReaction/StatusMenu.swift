import AppKit
import Carbon.HIToolbox
import OpenReactionCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let controller: AppController
    private let showOnboarding: () -> Void
    private let showSettings: () -> Void
    private let baseImage = AppResources.menuBarImage()
    private lazy var badgedImage = Self.badged(baseImage)
    /// Frontmost app when the menu opened; opening a status menu does not activate OpenReaction.
    private var frontmostApp: NSRunningApplication?
    #if OPENAPPS_OFFICIAL
    var updates: UpdateController?
    #endif

    init(controller: AppController, showOnboarding: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.controller = controller
        self.showOnboarding = showOnboarding
        self.showSettings = showSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateButton()
        observeChanges { [weak self] in
            guard let self else { return }
            _ = self.controller.isReady
            _ = self.controller.licenseStatusLine
            _ = self.controller.inputNotice
            _ = self.controller.permissions.snapshot
        } onChange: { [weak self] in
            self?.updateButton()
        }
    }

    /// The status item's frame in AppKit screen coordinates, or nil when it
    /// is not on any screen (for example hidden behind the notch).
    var buttonScreenFrame: CGRect? {
        guard let frame = statusItem.button?.window?.frame, !frame.isEmpty,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
        return frame
    }

    private var setupIncomplete: Bool { !controller.permissions.snapshot.isComplete }

    func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = setupIncomplete ? badgedImage : baseImage
        button.appearsDisabled = !controller.isReady && !setupIncomplete
        button.setAccessibilityLabel(setupIncomplete ? "OpenReaction, setup incomplete" : "OpenReaction")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()

        #if OPENAPPS_OFFICIAL
        if let version = updates?.readyVersion {
            let restart = item("Update ready — Restart", #selector(restartToUpdate))
            restart.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            restart.toolTip = "Installs OpenReaction \(version) and opens it again"
            menu.addItem(restart)
            menu.addItem(.separator())
        }
        #endif

        if setupIncomplete {
            let finish = item("Finish Setup…", #selector(openOnboarding))
            finish.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            menu.addItem(finish)
            menu.addItem(.separator())
        }

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if controller.permissions.allGranted {
            menu.addItem(item(controller.isEnabled ? "Pause OpenReaction" : "Resume OpenReaction", #selector(toggleEnabled)))
        }

        if let app = frontmostApp, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? bundleID
            let toggle = item("Suggest in \(name)", #selector(toggleFrontmostApp))
            toggle.state = controller.exclusions.isExcluded(bundleID) ? .off : .on
            menu.addItem(toggle)
        }

        menu.addItem(.separator())
        let settings = item("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        if !setupIncomplete {
            menu.addItem(item("Setup Guide…", #selector(openOnboarding)))
        }
        menu.addItem(item("About OpenReaction", #selector(showAbout)))
        menu.addItem(.separator())
        let quit = item("Quit OpenReaction", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var statusText: String {
        let permissions = controller.permissions
        if let notice = controller.inputNotice { return notice }
        if PermissionKind.allCases.contains(where: { permissions.status($0) == .stale }) { return "Permission needs a reset" }
        if controller.needsRelaunch { return "Needs a relaunch" }
        if !permissions.allGranted { return "Needs permissions" }
        if let line = controller.licenseStatusLine { return line }
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

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func showAbout() {
        Diagnostics.showAboutPanel(controller: controller)
    }

    #if OPENAPPS_OFFICIAL
    @objc private func restartToUpdate() {
        updates?.restartToUpdate()
    }
    #endif

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The template image with a small dot cut into its top-right corner. It
    /// stays a template, so macOS still tints it for the menu bar appearance.
    private static func badged(_ base: NSImage) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let diameter: CGFloat = 6.5
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenReaction, setup incomplete"
        return image
    }
}

