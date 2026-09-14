#if OPENAPPS_LICENSING
import AppKit
import Network
import OpenReactionCore
import SwiftUI

/// Owns the `LicenseManager` in official builds: schedules the daily check
/// and the trial's registration (launch, timers, wake, network back),
/// exposes state for the UI and tells the app whether the picker may run.
///
/// The manager lives on its own actor and hands over a `LicenseSnapshot`
/// right after its memory changes, before it touches the Keychain. The
/// entitlement is derived from that snapshot with the clock, so deadlines
/// and the feature lock never wait on storage: a snapshot that turns the
/// feature off locks the gate from the manager's thread at once
/// (`lockFeature`), and the UI follows on the main actor.
@MainActor
@Observable
final class LicenseController {
    let manager: LicenseManager
    private(set) var snapshot: LicenseSnapshot
    private(set) var state: LicenseState
    private(set) var isBusy = false
    private(set) var message: LicenseMessage?
    /// A key from a deep link, waiting for the user's confirmation.
    var pendingKey: String?
    /// Runs whenever the state may have changed (feature on/off, status line).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called from the manager's thread, synchronously, the moment a
    /// snapshot says the feature is off — before any storage runs.
    @ObservationIgnored var lockFeature: (@Sendable () -> Void)? {
        get { lockBox.lock }
        set { lockBox.lock = newValue }
    }
    private final class LockBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var _lock: (@Sendable () -> Void)?
        var lock: (@Sendable () -> Void)? {
            get { mutex.withLock { _lock } }
            set { mutex.withLock { _lock = newValue } }
        }
    }
    @ObservationIgnored private let lockBox = LockBox()

    @ObservationIgnored private var checkTimer: Timer?
    /// Fires at the next local entitlement change (a trial day boundary or
    /// its end, grace warning or end), independent of the network schedule.
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied = true

    /// Until the manager has loaded, there is no record: the feature is off.
    init(manager: LicenseManager) {
        self.manager = manager
        let initial = LicenseSnapshot(trialTiming: manager.trialTiming)
        snapshot = initial
        state = initial.state(now: Date())
    }

    /// Wires the snapshot feed, then loads storage on the license actor.
    private func subscribe() async {
        let feed = SnapshotFeed { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(snapshot) }
            }
        } lock: { [lockBox] in
            lockBox.lock?()
        }
        await manager.setOnChange { snapshot in feed.deliver(snapshot) }
        await manager.load()
    }

    /// Carries snapshots from the manager's actor: the lock runs there,
    /// synchronously; the rest lands on the main actor.
    private final class SnapshotFeed: Sendable {
        let toMain: @Sendable (LicenseSnapshot) -> Void
        let lock: @Sendable () -> Void
        init(toMain: @escaping @Sendable (LicenseSnapshot) -> Void, lock: @escaping @Sendable () -> Void) {
            self.toMain = toMain
            self.lock = lock
        }
        func deliver(_ snapshot: LicenseSnapshot) {
            if !snapshot.state(now: Date()).isFeatureEnabled { lock() }
            toMain(snapshot)
        }
    }

    private func receive(_ snapshot: LicenseSnapshot) {
        self.snapshot = snapshot
        refresh()
    }

    var isFeatureEnabled: Bool { state.isFeatureEnabled }

    var storageError: LicenseStoreError? { snapshot.storageError }
    var trialStorageError: LicenseStoreError? { snapshot.trialStorageError }
    var journalError: Bool { snapshot.journalError }

    func start() {
        // Storage, the provisional trial and the launch check run on the
        // license actor; nothing here waits for them.
        Task {
            await subscribe()
            await manager.checkOnLaunch()
            refresh()
        }
        scheduleTimers()

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deadlineOrClock() }
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

    func removeThisMac() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = await manager.removeThisMac()
        refresh()
    }

    /// With a license: check it now. Without: retry storage and ask the
    /// trial registry now, whatever the backoff says.
    func tryAgain() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if snapshot.record != nil {
            await manager.check()
        } else {
            await manager.tick(wake: true)
        }
        refresh()
    }

    func clearMessage() {
        message = nil
    }

    /// Saves the trial's latest `last_seen_at` before the process exits.
    /// Waits at most `quitSaveBound`: a stuck Keychain never holds up Quit,
    /// and at most the last hour of observed time is lost.
    func saveBeforeQuit() async {
        let manager = self.manager
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { @LicenseActor in
                manager.saveTrialBeforeQuit()
                once.resume()
            }
            Task {
                try? await Task.sleep(for: Self.quitSaveBound)
                once.resume()
            }
        }
    }

    static let quitSaveBound: Duration = .seconds(2)

    private final class ResumeOnce: @unchecked Sendable {
        private let mutex = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            mutex.withLock {
                continuation?.resume()
                continuation = nil
            }
        }
    }

    // MARK: - Scheduling

    /// Wake from sleep or the network back: an unregistered trial asks the
    /// registry now.
    /// Wake from sleep: also checks the clock against the trial's last seen time.
    private func didWake() {
        refresh()
        Task {
            await manager.wake()
            refresh()
        }
    }

    private func wakeOrNetwork() {
        // Local deadlines first: a trial that ended while asleep is off now.
        refresh()
        tick(wake: true)
    }

    /// A local deadline passed, or the clock changed.
    private func deadlineOrClock() {
        refresh()
        tick()
    }

    /// The manager's housekeeping: note time, retry storage and cleanups,
    /// check or register if due. Everything it changes lands through `refresh`.
    private func tick(wake: Bool = false) {
        Task {
            await manager.tick(wake: wake)
            refresh()
        }
    }

    private func scheduleTimers() {
        checkTimer?.invalidate()
        checkTimer = nil
        if let at = snapshot.nextCheckAt {
            checkTimer = makeTimer(after: at.timeIntervalSinceNow) { [weak self] in
                self?.tick()
            }
        }
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let deadline = snapshot.nextDeadline {
            deadlineTimer = makeTimer(after: deadline.timeIntervalSinceNow + 1) { [weak self] in
                self?.deadlineOrClock()
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

    /// Re-evaluates the state from the snapshot and the clock — never from
    /// storage — and re-arms both timers. Cheap; called on every timer and event.
    private func refresh() {
        let previous = state
        state = snapshot.state(now: Date())
        scheduleTimers()
        if previous != state { onChange?() }
    }

    // MARK: - Copy

    static let clockBehindText = "Your Mac’s clock is behind. Set the correct date and time to keep using your free trial"

    /// "Free trial: N days left", or "less than a day left" on the last day.
    static func trialText(daysLeft days: Int) -> String {
        days <= 1 ? "Free trial: less than a day left" : "Free trial: \(days) days left"
    }

    /// One line for the status menu while not simply licensed. The end of
    /// the trial is said here, in the menu bar item; nothing opens on its own.
    var statusLine: String? {
        switch state {
        case .licensed: nil
        case .trialUnavailable:
            if snapshot.storageError != nil {
                "Can’t read the license from the Keychain"
            } else if snapshot.trialStorageError != nil {
                "Can’t read or save the free trial in the Keychain"
            } else {
                "Starting your free trial…"
            }
        case .trial(let days): Self.trialText(daysLeft: days)
        case .trialNeedsConnection: "Connect to the internet to continue your free trial"
        case .trialClockBehind: Self.clockBehindText
        case .trialEnded: "Your free trial has ended — buy in Settings"
        case .grace(let days, let warn): warn ? "Connect to the internet within \(days) day\(days == 1 ? "" : "s") to keep using OpenReaction" : nil
        case .checkRequired: "Connect to the internet to verify your license"
        case .revoked: "License no longer active on this Mac"
        }
    }
}
#endif
