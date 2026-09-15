import AppKit
import OpenReactionCore
#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var statusMenu: StatusMenuController?
    private var onboarding: OnboardingWindowController?
    private var settings: SettingsWindowController?
    private var loginItem: LoginItem?
    private var preview: PreviewHarness?
    #if OPENAPPS_LICENSING
    private var license: LicenseController?
    #endif
    #if OPENAPPS_OFFICIAL
    private var updates: Updater?
    #endif

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
        registerURLHandler()

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
        #if OPENAPPS_LICENSING
        let license = LicenseController(manager: LicenseManager(
            products: LicensingConfig.products,
            client: DodoLicenseClient(host: LicensingConfig.host),
            store: KeychainLicenseStore(),
            journal: DefaultsInvalidationJournal(),
            trialStore: KeychainTrialStore(),
            registry: URLSessionTrialRegistryClient(endpoint: LicensingConfig.trialRegistryURL, environment: LicensingConfig.environment),
            device: PlatformDeviceIdentity(),
            trialTiming: Licensing.trialTiming
        ))
        self.license = license
        license.onChange = { [weak controller, weak license] in
            guard let controller, let license else { return }
            controller.setLicense(allowsFeature: license.isFeatureEnabled, statusLine: license.statusLine)
        }
        // From the manager's thread, before storage: the gate stops
        // authorizing at once; the tap's stop and the UI follow on main.
        license.lockFeature = controller.featureLock()
        controller.setLicense(allowsFeature: license.isFeatureEnabled, statusLine: license.statusLine)
        let settings = SettingsWindowController(controller: controller, loginItem: loginItem, license: license) { [weak onboarding] in
            onboarding?.show()
        }
        #else
        let settings = SettingsWindowController(controller: controller, loginItem: loginItem) { [weak onboarding] in
            onboarding?.show()
        }
        #endif
        #if OPENAPPS_OFFICIAL
        // Independent of licensing: updates never depend on the license or trial state.
        let updates = Updates.make()
        self.updates = updates
        settings.updates = updates
        statusMenu.updates = updates
        #endif
        controller.onStateChange = { [weak statusMenu] in statusMenu?.updateButton() }
        onboarding.model.onOpenSettings = { [weak settings] in settings?.show() }
        self.controller = controller
        self.loginItem = loginItem
        self.statusMenu = statusMenu
        self.onboarding = onboarding
        self.settings = settings

        // Reads permissions and tries the tap once, so the launch decision
        // below sees current state. Update-test builds never touch either.
        let usesEventTap = !UpdateTesting.disablesEventTap
        if usesEventTap {
            controller.start()
        }
        #if OPENAPPS_LICENSING
        license.start()
        #endif
        #if OPENAPPS_OFFICIAL
        updates?.start()
        #endif
        if usesEventTap, OnboardingWindowController.shouldShowOnLaunch(permissions: controller.permissions) {
            onboarding.show()
        }
    }

    /// Quitting drains what the gate still owes the host before the tap goes
    /// away with the process. The wait ends with the drain's outcome (or the
    /// controller's one bound, as a logged failure); the app terminates either
    /// way, since keeping a process the user quit is worse than a logged
    /// unconfirmed delivery.
    ///
    /// Official builds also save the trial's latest observed time, bounded
    /// by `LicenseController.quitSaveBound`, alongside the drain, and as the
    /// very last thing hand the quit to the updater: a staged update whose
    /// consent still holds is exchanged in (one atomic rename, evaluated
    /// against the running app's identity first), and after "Restart to
    /// Update" the app is reopened; a failed restart install cancels the
    /// quit so the user sees why.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let drain = controller?.isTapRunning == true ? controller : nil
        #if OPENAPPS_LICENSING
        let license = self.license
        #else
        let license: Never? = nil
        #endif
        #if OPENAPPS_OFFICIAL
        let updates = self.updates
        #else
        let updates: Never? = nil
        #endif
        guard drain != nil || license != nil || updates != nil else { return .terminateNow }
        Task {
            #if OPENAPPS_LICENSING
            let saved = Task { await license?.saveBeforeQuit() }
            #endif
            await drain?.prepareToQuit()
            #if OPENAPPS_LICENSING
            await saved.value
            #endif
            #if OPENAPPS_OFFICIAL
            if let updates, await !updates.finishQuit() {
                // The tap was stopped for the quit; a relaunch that did not happen means the app stays.
                controller?.resumeAfterCancelledQuit()
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            #endif
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Deep link

    /// `openreaction://activate?key=…` from the website's thanks page. It only
    /// pre-fills the key; the user confirms in Settings → License. Builds
    /// without licensing ignore it.
    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string), url.scheme?.lowercased() == "openreaction",
              url.host?.lowercased() == "activate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return }
        #if OPENAPPS_LICENSING
        license?.pendingKey = key
        settings?.show()
        #endif
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
