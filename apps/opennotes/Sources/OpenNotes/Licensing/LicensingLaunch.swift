import AppKit
import OpenAppsLicensing
import OpenNotesCore
import SwiftUI
#if OPENAPPS_LICENSING
import OpenAppsLicensingClients
#endif

/// The launch path's licensing half (LICENSING.md): in an official build
/// the record store, the manager and the controller bound to
/// `licenseStatus`, with the fresh-install defaults decided once storage
/// says whether the install is fresh; in a build from source nothing to
/// wait for. Kept beside the controller so `AppDelegate` only calls in.
extension AppDelegate {
    func startLicensing() {
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
        licenseController = license
        // One projected entitlement for every consumer: the model and the
        // store ask it at every action and at the file, the views on every
        // body.
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
                guard let self, let license = self.licenseController else { return }
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
        // Licensing compiled out: no record store to wait for, so the
        // install is fresh when no earlier launch left preferences behind.
        // An update-test build never registers a login item.
        if !UpdateTesting.isCompiledIn {
            loginItem.applyDefaultIfNeeded(storageIsFresh: true)
        }
        #if OPENAPPS_OFFICIAL
        updates?.applyCheckDefaultIfNeeded(storageIsFresh: true)
        #endif
        #endif
        licenseStatus.enterKey = { [weak self] in self?.showLicense(keyField: true) }
        licenseStatus.openLicense = { [weak self] in self?.showLicense() }
    }

    #if OPENAPPS_LICENSING
    /// The controller published a change: the views re-read the projected
    /// entitlement (the model and the store ask it again at every action
    /// regardless), and the fresh-install defaults — Open at login and
    /// automatic update checks — are decided once storage says whether this
    /// install is fresh (`FreshInstallDefault`).
    func applyLicense() {
        guard let license = licenseController else { return }
        licenseStatus.publish()
        licenseStatus.setBusy(license.isBusy)
        loginItem.applyDefaultIfNeeded(storageIsFresh: license.freshInstall)
        #if OPENAPPS_OFFICIAL
        updates?.applyCheckDefaultIfNeeded(storageIsFresh: license.freshInstall)
        #endif
    }
    #endif

    /// The end of `applicationShouldTerminate`, after every note is
    /// flushed: official builds save the trial's latest observed time
    /// before the process exits, bounded by `LicenseController.quitSaveBound`,
    /// so a stuck disk never holds up Quit, and as the very last thing hand
    /// the quit to the updater: a staged update whose consent still holds
    /// is exchanged in (one atomic rename, evaluated against the running
    /// app's identity first), and after "Restart" the app is reopened; a
    /// failed restart install cancels the quit so the user sees why. A
    /// source build has nothing to wait for.
    func finishTerminate() -> NSApplication.TerminateReply {
        #if OPENAPPS_LICENSING
        let license = licenseController
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

    // MARK: - Deep link

    /// The one Apple-event handler for `opennotes://` links (scripts/bundle.sh
    /// registers the scheme in every build). Dispatch is by host in
    /// `openDeepLink`; a later host is added there, never as a second
    /// handler.
    func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        openDeepLink(url)
    }

    /// Dispatches by host: `activate` pre-fills a license key; `new`,
    /// `open` and `append` go through the automation door
    /// (Automation/Automation.swift), which asks the license; anything
    /// else is left alone.
    func openDeepLink(_ url: URL) {
        if openActivateLink(url) { return }
        if let request = AutomationLink.request(from: url) { automation?.openLink(request) }
    }

    /// `opennotes://activate?key=…` from the website's thanks page: only
    /// pre-fills the key, and the user confirms in Settings → License;
    /// builds without licensing ignore it. True when the link was an
    /// activate link.
    @discardableResult
    func openActivateLink(_ url: URL) -> Bool {
        guard let key = ActivateLink.key(from: url) else { return false }
        #if OPENAPPS_LICENSING
        licenseController?.pendingKey = key
        showLicense()
        #else
        _ = key
        #endif
        return true
    }

    // MARK: - What Settings shows

    /// Settings → License (official builds) and Settings → Updates (every
    /// build: the source flavour says it has no updater), before About.
    func licensingSettingsSections(navigation: SettingsNavigation) -> [AnyView] {
        var sections: [AnyView] = []
        #if OPENAPPS_LICENSING
        if let licenseController {
            sections.append(AnyView(LicenseSection(license: licenseController, navigation: navigation)))
        }
        #endif
        #if OPENAPPS_OFFICIAL
        sections.append(AnyView(UpdatesSection(updates: updates)))
        #else
        sections.append(AnyView(UpdatesSection()))
        #endif
        return sections
    }
}

/// `opennotes://activate?key=…`: the key, trimmed, or nil for any other
/// link (another host, no key, an empty key).
nonisolated enum ActivateLink {
    static let scheme = "opennotes"
    static let host = "activate"

    static func key(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }
}
