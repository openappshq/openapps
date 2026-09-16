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
                showSettings: delegate.showSettings
            )
        } label: {
            MenuBarLabel(model: delegate.model, preferences: delegate.preferences, license: delegate.licenseStatus)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The symbol, plus the chosen readout. The readout uses the system font like
/// every other status item; the brand fonts belong inside the dashboard.
/// While the license keeps the readings off, the symbol stands alone.
private struct MenuBarLabel: View {
    let model: MetricsModel
    let preferences: Preferences
    let license: LicenseStatus

    var body: some View {
        // Asked now, not remembered: a lapsed trial hides the readout on the
        // next body even before the model dropped its sample.
        let text = MenuBarText.readout(
            preferences.menuBarReadout, access: license.hasAccess(), hasSample: model.hasSample, cpu: model.cpu, memory: model.memory
        ) ?? ""
        Label {
            if !text.isEmpty {
                Text(text).font(.system(size: 12).monospacedDigit())
            }
        } icon: {
            Image(nsImage: AppResources.menuBarImage())
        }
        .accessibilityLabel(text.isEmpty ? "Hertz" : "Hertz, \(preferences.menuBarReadout.title) \(text)")
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
}

/// Owns the long-lived objects: the metrics model, preferences, login item,
/// licensing and the two windows. Menu-bar only: no Dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MetricsModel()
    let preferences = Preferences()
    let loginItem = LoginItem()
    let licenseStatus = LicenseStatus()
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    #if OPENAPPS_LICENSING
    private var license: LicenseController?
    #endif

    override init() {
        super.init()
        AppResources.registerFonts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = AppResources.appIcon() { NSApp.applicationIconImage = icon }
        registerURLHandler()

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
        // launch left preferences behind.
        loginItem.applyDefaultIfNeeded(storageIsFresh: true)
        #endif
        licenseStatus.enterKey = { [weak self] in self?.showLicense(keyField: true) }
        licenseStatus.openLicense = { [weak self] in self?.showLicense() }

        // Once, on the first launch of the packaged app. `swift run` builds
        // skip it so a development loop never opens a window.
        if Bundle.main.bundleURL.pathExtension == "app", OnboardingLaunch.shouldShow(store: UserDefaults.standard) {
            showGuide()
        }
    }

    #if OPENAPPS_LICENSING
    /// The controller published a change: the views re-read the projected
    /// entitlement, collection is started or stopped (the model re-checks
    /// access on every tick regardless), and the login-item default is
    /// decided once storage says whether this install is fresh.
    private func applyLicense() {
        guard let license else { return }
        licenseStatus.publish()
        licenseStatus.setBusy(license.isBusy)
        if license.isFeatureEnabled { model.start() } else { model.stop() }
        loginItem.applyDefaultIfNeeded(storageIsFresh: license.freshInstall)
    }

    /// Official builds save the trial's latest observed time before the
    /// process exits, bounded by `LicenseController.quitSaveBound`, so a
    /// stuck disk never holds up Quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let license else { return .terminateNow }
        Task {
            await license.saveBeforeQuit()
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
