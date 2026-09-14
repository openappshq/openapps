#if OPENAPPS_LICENSING
import AppKit
import Network
import OpenReactionCore
import SwiftUI

/// Owns the `LicenseManager` in official builds: schedules the daily check
/// (launch, every 24 h, wake, network back), exposes state for the UI and
/// tells the app whether the picker may run.
@MainActor
@Observable
final class LicenseController {
    let manager: LicenseManager
    private(set) var state: LicenseState
    private(set) var isBusy = false
    private(set) var message: LicenseMessage?
    /// A key from a deep link, waiting for the user's confirmation. `kind`
    /// is `.trial` when the link came from the trial checkout.
    struct PendingKey: Equatable {
        let key: String
        let kind: LicenseKind?
    }

    var pendingKey: PendingKey?
    /// Runs whenever the state may have changed (feature on/off, status line).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var checkTimer: Timer?
    /// Fires at the next local entitlement change (trial expiry, grace
    /// warning or end), independent of the network schedule.
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied = true

    init(manager: LicenseManager) {
        self.manager = manager
        state = manager.state
    }

    var isFeatureEnabled: Bool { state.isFeatureEnabled }

    var trialUsed: Bool { manager.trialUsed }

    func start() {
        // Launch check in the background; never delays launch or the picker.
        Task {
            await manager.checkOnLaunch()
            refresh()
        }
        scheduleTimers()

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeOrNetwork() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let cameBack = satisfied && !self.networkWasSatisfied
                    self.networkWasSatisfied = satisfied
                    if cameBack { self.wakeOrNetwork() }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "space.openapps.openreaction.license.network"))
    }

    // MARK: - User actions

    func activate(key: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = await manager.activate(key: key)
        refresh()
    }

    /// The trial route (trial key field or a trial deep link): refused
    /// locally, without calling Dodo, when the trial was already used here.
    func activateTrial(key: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = await manager.activate(key: key, expecting: .trial)
        refresh()
    }

    func removeThisMac() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = await manager.removeThisMac()
        refresh()
    }

    func tryAgain() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await manager.check()
        refresh()
    }

    func forgetRevokedRecord() {
        manager.forgetRevokedRecord()
        refresh()
    }

    func clearMessage() {
        message = nil
    }

    // MARK: - Scheduling

    private func wakeOrNetwork() {
        // Local deadlines first: a trial that ended while asleep is off now.
        refresh()
        Task { await runCheckIfDue() }
    }

    private func runCheckIfDue() async {
        await manager.checkIfDue()
        await manager.retryPendingCleanups()
        refresh()
    }

    private func scheduleTimers() {
        checkTimer?.invalidate()
        checkTimer = nil
        if let delay = manager.nextCheckDelay {
            checkTimer = makeTimer(after: delay) { [weak self] in
                guard let self else { return }
                Task { await self.runCheckIfDue() }
            }
        }
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let deadline = manager.nextDeadline {
            deadlineTimer = makeTimer(after: deadline.timeIntervalSinceNow + 1) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func makeTimer(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(1, delay), repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = min(60, max(1, delay * 0.05))
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Re-evaluates the state from the clock, records that time has passed,
    /// and re-arms both timers. Cheap; called on every timer and event.
    private func refresh() {
        manager.noteTime()
        let previous = state
        state = manager.state
        scheduleTimers()
        if previous != state { onChange?() }
    }

    // MARK: - Copy

    /// One line for the status menu while not simply licensed.
    var statusLine: String? {
        switch state {
        case .licensed: nil
        case .unlicensed: manager.storageError == nil ? "Not licensed — start a trial or buy in Settings" : "Can’t read the license from the Keychain"
        case .trial(let days): "Trial: about \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded: "Trial ended — buy in Settings"
        case .grace(let days, let warn): warn ? "Connect to the internet within \(days) day\(days == 1 ? "" : "s") to keep using OpenReaction" : nil
        case .checkRequired: "Connect to the internet to verify your license"
        case .revoked: "License no longer active on this Mac"
        }
    }
}
#endif
