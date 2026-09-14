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
    /// A key arrived by deep link and waits for the user's confirmation.
    var pendingKey: String?
    /// Runs whenever the state may have changed (feature on/off, status line).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
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
        Task { await runCheckIfDue() }
        scheduleTimer()

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeOrNetwork() }
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

    /// The "Start 3-day trial" path: refuses locally when the trial was used.
    func startTrial(key: String) async {
        if manager.refusesTrialLocally {
            message = .trialAlreadyUsed
            return
        }
        await activate(key: key)
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
        Task { await runCheckIfDue() }
    }

    private func runCheckIfDue() async {
        await manager.checkIfDue()
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard let delay = manager.nextCheckDelay else { return }
        let timer = Timer(timeInterval: max(1, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.runCheckIfDue() }
            }
        }
        timer.tolerance = min(60, max(1, delay * 0.05))
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let previous = state
        state = manager.state
        scheduleTimer()
        if previous != state { onChange?() }
    }

    // MARK: - Copy

    /// One line for the status menu while not simply licensed.
    var statusLine: String? {
        switch state {
        case .licensed: nil
        case .unlicensed: "Not licensed — start a trial or buy in Settings"
        case .trial(let days): "Trial: about \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded: "Trial ended — buy in Settings"
        case .grace(let days, let warn): warn ? "Connect to the internet within \(days) day\(days == 1 ? "" : "s") to keep using OpenReaction" : nil
        case .checkRequired: "Connect to the internet to verify your license"
        case .revoked: "License no longer active on this Mac"
        }
    }
}
#endif
