#if OPENAPPS_OFFICIAL
import AppKit
import OpenReactionCore
import os
import Sparkle

/// The in-app updater of official builds (RELEASES.md, "In-app updater"),
/// on Sparkle 2. Builds from source compile none of this.
///
/// Info.plist (scripts/bundle.sh) pins the feed, the update key and signed
/// feeds, and starts both toggles off: until the user turns automatic checks
/// on, the app contacts the feed only for "Check Now". With them on, Sparkle
/// checks on launch and every 24 hours, this controller adds a check on wake
/// when one is due and one retry an hour after a failed check, and a
/// downloaded update installs on the next quit, or at once from "Update
/// ready — Restart". Nothing here reads the license or trial state.
@MainActor
@Observable
final class UpdateController: NSObject {
    let location: UpdateLocation
    private(set) var automaticChecks: Bool
    private(set) var automaticDownloads: Bool
    private(set) var canCheckNow = false
    private(set) var lastCheck: Date?
    /// The version waiting to be installed on quit, once it is downloaded and verified.
    private(set) var readyVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    private static let log = Logger(subsystem: "com.openappshq.openreaction", category: "updates")

    override init() {
        location = Self.currentLocation()
        automaticChecks = UpdatePolicy.automaticChecksByDefault
        automaticDownloads = UpdatePolicy.automaticDownloadsByDefault
        super.init()
    }

    /// Starts Sparkle, unless the app runs from somewhere it cannot update
    /// itself; Settings then asks the user to move it instead.
    func start() {
        guard controller == nil else { return }
        guard location == .updatable else {
            Self.log.notice("Updates are off: the app runs from a \(String(describing: self.location), privacy: .public) location")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            Self.log.error("The updater could not start: \(error.localizedDescription, privacy: .public)")
            self.controller = nil
            return
        }
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        canCheckNow = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
        // Sparkle changes both on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheckNow = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                MainActor.assumeIsolated { self?.lastCheck = value }
            },
        ]
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInBackgroundIfDue() }
        }
    }

    var isAvailable: Bool { controller != nil }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticChecks = updater.automaticallyChecksForUpdates
        if !enabled {
            // Downloading on its own only makes sense while checking on its own.
            updater.automaticallyDownloadsUpdates = false
            automaticDownloads = false
            retry?.cancel()
        }
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        automaticDownloads = updater.automaticallyDownloadsUpdates
    }

    /// "Check Now": always a deliberate request, shown in Sparkle's window.
    func checkNow() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /// "Update ready — Restart": installs the downloaded update and relaunches.
    func restartToUpdate() {
        installNow?()
    }

    private func checkInBackgroundIfDue() {
        guard let updater = controller?.updater, !updater.sessionInProgress,
              UpdatePolicy.isAutomaticCheckDue(
                  automaticChecks: updater.automaticallyChecksForUpdates,
                  location: location, lastCheck: updater.lastUpdateCheckDate, now: Date())
        else { return }
        updater.checkForUpdatesInBackground()
    }

    private func scheduleRetry() {
        retry?.cancel()
        guard let delay = UpdatePolicy.retryDelay(consecutiveFailures: consecutiveFailures) else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let updater = self.controller?.updater,
                  updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    private static func currentLocation() -> UpdateLocation {
        let bundle = Bundle.main.bundleURL
        let volumeReadOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let container = bundle.deletingLastPathComponent().path
        let writable = FileManager.default.isWritableFile(atPath: container)
            && FileManager.default.isWritableFile(atPath: bundle.path)
        return UpdateLocation.classify(bundlePath: bundle.path, volumeIsReadOnly: volumeReadOnly, containerIsWritable: writable)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        readyVersion = item.displayVersionString
        Self.log.notice("Update \(item.displayVersionString, privacy: .public) is ready and installs on quit")
        UpdateTesting.updateIsReady(installNow: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
        UpdateTesting.cycleFinished(error: error)
        guard updateCheck == .updatesInBackground else { return }
        if let error = error as NSError?, !Self.isBenign(error) {
            consecutiveFailures += 1
            Self.log.error("Background update check failed: \(error.localizedDescription, privacy: .public)")
            scheduleRetry()
        } else {
            consecutiveFailures = 0
            retry?.cancel()
        }
    }

    /// Outcomes that are not failures: nothing newer, or the user declined.
    private static func isBenign(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        return error.code == Int(SUError.noUpdateError.rawValue)
            || error.code == Int(SUError.installationCanceledError.rawValue)
    }
}

extension UpdateController: nonisolated SPUStandardUserDriverDelegate {
    /// A menu-bar app has no Dock icon to bounce: an update found by a
    /// scheduled check with automatic downloads off is shown gently, not by
    /// stealing focus while the user types.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif
