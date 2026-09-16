import AppKit
import HertzCore
import OpenAppsLicensing
#if OPENAPPS_LICENSING
import OpenAppsLicensingClients
#endif
import SwiftUI

@main
struct HertzApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                model: delegate.model,
                preferences: delegate.preferences,
                license: delegate.licenseStatus,
                updates: delegate.updateStatus,
                showSettings: delegate.showSettings
            )
        } label: {
            MenuBarLabel(model: delegate.model, preferences: delegate.preferences, license: delegate.licenseStatus, updates: delegate.updateStatus)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The symbol, plus the chosen readout. The readout uses the system font like
/// every other status item; the brand fonts belong inside the dashboard.
/// While the license keeps the readings off, the symbol stands alone. Once
/// an update is staged, a small arrow joins it (RELEASES.md: "Update ready —
/// Restart" is one click away, in the dashboard footer).
private struct MenuBarLabel: View {
    let model: MetricsModel
    let preferences: Preferences
    let license: LicenseStatus
    let updates: UpdateStatus

    var body: some View {
        // Asked now, not remembered: a lapsed trial hides the readout on the
        // next body even before the model dropped its sample.
        let text = MenuBarText.readout(
            preferences.menuBarReadout, access: license.hasAccess(), hasSample: model.hasSample, cpu: model.cpu, memory: model.memory
        ) ?? ""
        let updateReady = MenuBarText.showsUpdateHint(updates.hint())
        Label {
            HStack(spacing: 3) {
                if !text.isEmpty {
                    Text(text).font(.system(size: 12).monospacedDigit())
                }
                if updateReady {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 10))
                }
            }
        } icon: {
            Image(nsImage: AppResources.menuBarImage())
        }
        .accessibilityLabel(MenuBarText.accessibilityLabel(readout: preferences.menuBarReadout, text: text, updateReady: updateReady))
    }
}

/// What the menu-bar item prints beside the pulse: the chosen readout while
/// the license allows the readings now and a sample is held; nothing
/// otherwise (the pulse alone).
nonisolated enum MenuBarText {
    static func readout(_ readout: MenuBarReadout, access: Bool, hasSample: Bool, cpu: CPUSnapshot, memory: MemorySnapshot) -> String? {
        guard access, hasSample else { return nil }
        let text = readout.text(cpu: cpu, memory: memory)
        return text.isEmpty ? nil : text
    }

    /// The menu bar hints only once an update is staged and waits for a
    /// restart; a found or downloading update stays in the footer.
    static func showsUpdateHint(_ hint: UpdateHint?) -> Bool {
        if case .ready = hint { return true }
        return false
    }

    static func accessibilityLabel(readout: MenuBarReadout, text: String, updateReady: Bool) -> String {
        var label = text.isEmpty ? "Hertz" : "Hertz, \(readout.title) \(text)"
        if updateReady { label += ", update ready" }
        return label
    }
}

/// Owns the long-lived objects: the metrics model, preferences, login item,
/// licensing, the updater and the two windows. Menu-bar only: no Dock icon,
/// no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MetricsModel()
    let preferences = Preferences()
    let loginItem = LoginItem()
    let licenseStatus = LicenseStatus()
    let updateStatus = UpdateStatus()
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    #if OPENAPPS_LICENSING
    private var license: LicenseController?
    #endif
    #if OPENAPPS_OFFICIAL
    private var updates: Updates?
    #endif

    override init() {
        super.init()
        AppResources.registerFonts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = AppResources.appIcon() { NSApp.applicationIconImage = icon }
        registerURLHandler()

        #if OPENAPPS_OFFICIAL
        // Independent of licensing: updates never depend on the license or
        // trial state. Created now, before this launch writes any
        // preferences, so its fresh-install default reads the launch's.
        let updates = Updates.make()
        self.updates = updates
        updates?.bind(updateStatus)
        #endif

        #if OPENAPPS_LICENSING
        // Both records live in one encrypted file store the app owns, keyed
        // to this Mac (LICENSING.md, "Record store"); never the Keychain.
        let device = PlatformDeviceIdentity()
        let records = FileRecordStore(appID: Licensing.appID, device: device)
        let license = LicenseController(manager: LicenseManager(
            appID: Licensing.appID,
            products: LicensingConfig.products,
            client: DodoLicenseClient(host: LicensingConfig.host),
            store: records,
            journal: DefaultsInvalidationJournal(suiteName: Licensing.journalSuite),
            trialStore: records,
            registry: URLSessionTrialRegistryClient(
                endpoint: LicensingConfig.trialRegistryURL, appID: Licensing.appID, environment: LicensingConfig.environment
            ),
            device: device,
            trialTiming: Licensing.trialTiming
        ))
        self.license = license
        // One projected entitlement for every consumer: the model asks it on
        // every read, the views and exports on every evaluation.
        model.access = { [weak license] in license?.isFeatureEnabled ?? false }
        licenseStatus.bind(
            access: { [weak license] in license?.isFeatureEnabled ?? false },
            state: { [weak license] in license?.state },
            restriction: { [weak license] in license?.restriction },
            badge: { [weak license] in license?.badge },
            canBuy: LicensingConfig.buyURL != nil
        )
        licenseStatus.buy = { if let url = LicensingConfig.buyURL { NSWorkspace.shared.open(url) } }
        licenseStatus.tryAgain = { [weak self] in
            Task { [weak self] in
                guard let self, let license = self.license else { return }
                // The controller reports state changes, not the run itself:
                // the card's buttons wait here until the retry has answered.
                self.licenseStatus.setBusy(true)
                await license.tryAgain()
                self.applyLicense()
            }
        }
        license.onChange = { [weak self] in self?.applyLicense() }
        applyLicense()
        license.start()
        #else
        // Licensing compiled out: every reading on, from the first tick.
        model.start()
        // No record store to wait for: the install is fresh when no earlier
        // launch left preferences behind. An update-test build never
        // registers a login item.
        if !UpdateTesting.isCompiledIn {
            loginItem.applyDefaultIfNeeded(storageIsFresh: true)
        }
        #if OPENAPPS_OFFICIAL
        updates?.applyCheckDefaultIfNeeded(storageIsFresh: true)
        #endif
        #endif
        licenseStatus.enterKey = { [weak self] in self?.showLicense(keyField: true) }
        licenseStatus.openLicense = { [weak self] in self?.showLicense() }
        #if OPENAPPS_OFFICIAL
        // Recovers an interrupted swap; checks only if the toggle is on and
        // a check is due.
        updates?.updater.start()
        #endif

        // Once, on the first launch of the packaged app. `swift run` builds
        // skip it so a development loop never opens a window; update-test
        // builds never open one either.
        if Bundle.main.bundleURL.pathExtension == "app", !UpdateTesting.isCompiledIn,
           OnboardingLaunch.shouldShow(store: UserDefaults.standard) {
            showGuide()
        }
    }

    #if OPENAPPS_LICENSING
    /// The controller published a change: the views re-read the projected
    /// entitlement, collection is started or stopped (the model re-checks
    /// access on every tick regardless), and the fresh-install defaults —
    /// Open at login and automatic update checks — are decided once storage
    /// says whether this install is fresh (`FreshInstallDefault`).
    private func applyLicense() {
        guard let license else { return }
        licenseStatus.publish()
        licenseStatus.setBusy(license.isBusy)
        if license.isFeatureEnabled { model.start() } else { model.stop() }
        loginItem.applyDefaultIfNeeded(storageIsFresh: license.freshInstall)
        #if OPENAPPS_OFFICIAL
        updates?.applyCheckDefaultIfNeeded(storageIsFresh: license.freshInstall)
        #endif
    }
    #endif

    #if OPENAPPS_LICENSING || OPENAPPS_OFFICIAL
    /// Official builds save the trial's latest observed time before the
    /// process exits, bounded by `LicenseController.quitSaveBound`, so a
    /// stuck disk never holds up Quit, and as the very last thing hand the
    /// quit to the updater: a staged update whose consent still holds is
    /// exchanged in (one atomic rename, evaluated against the running app's
    /// identity first), and after "Restart" the app is reopened; a failed
    /// restart install cancels the quit so the user sees why.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if OPENAPPS_LICENSING
        let license = self.license
        #else
        let license: Never? = nil
        #endif
        #if OPENAPPS_OFFICIAL
        let updater = updates?.updater
        #else
        let updater: Never? = nil
        #endif
        guard license != nil || updater != nil else { return .terminateNow }
        Task {
            #if OPENAPPS_LICENSING
            await license?.saveBeforeQuit()
            #endif
            #if OPENAPPS_OFFICIAL
            if let updater, await !updater.finishQuit() {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            #endif
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    #endif

    func showSettings() {
        settings().show()
    }

    /// Settings → License: the pill, the dashboard card and the guide land
    /// here. `keyField` puts the cursor in the key field ("Enter a key").
    func showLicense(keyField: Bool = false) {
        settings().showLicense(keyField: keyField)
    }

    private func settings() -> SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        #if OPENAPPS_LICENSING
        let controller = SettingsWindowController(
            model: model, preferences: preferences, loginItem: loginItem, license: license,
            showGuide: { [weak self] in self?.showGuide() }
        )
        #else
        let controller = SettingsWindowController(
            model: model, preferences: preferences, loginItem: loginItem,
            showGuide: { [weak self] in self?.showGuide() }
        )
        #endif
        #if OPENAPPS_OFFICIAL
        controller.updates = updates
        #endif
        settingsWindow = controller
        return controller
    }

    func showGuide() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(loginItem: loginItem, license: licenseStatus)
        }
        onboarding?.show()
    }

    /// Opening Hertz again from Finder or Spotlight while it runs: the
    /// status item can be hidden by the notch or a crowded menu bar, so this
    /// always leads to Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Deep link

    /// `hertz://activate?key=…` from the website's thanks page. It only
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
              let url = URL(string: string), url.scheme?.lowercased() == "hertz",
              url.host?.lowercased() == "activate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return }
        #if OPENAPPS_LICENSING
        license?.pendingKey = key
        showLicense()
        #endif
    }
}
