#if OPENAPPS_LICENSING
import AppKit
import Network
import OpenReactionCore
import SwiftUI

/// Owns the `LicenseManager` in official builds: schedules the daily check
/// (launch, every 24 h, wake, network back), exposes state for the UI and
/// tells the app whether the picker may run.
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
    /// A key from a deep link, waiting for the user's confirmation. `kind`
    /// is `.trial` when the link came from the trial checkout.
    struct PendingKey: Equatable {
        let key: String
        let kind: LicenseKind?
    }

    var pendingKey: PendingKey?
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
    /// Fires at the next local entitlement change (trial expiry, grace
    /// warning or end), independent of the network schedule.
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied = true

    /// Until the manager has loaded, there is no record: the feature is off.
    init(manager: LicenseManager) {
        self.manager = manager
        let initial = LicenseSnapshot()
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

    var trialUsed: Bool { snapshot.trialUsed }
    var storageError: LicenseStoreError? { snapshot.storageError }
    var journalError: Bool { snapshot.journalError }

    func start() {
        // Storage and the launch check run on the license actor; nothing
        // here waits for them.
        Task {
            await subscribe()
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

    func clearMessage() {
        message = nil
    }

    // MARK: - Scheduling

    private func wakeOrNetwork() {
        // Local deadlines first: a trial that ended while asleep is off now.
        refresh()
        tick()
    }

    /// The manager's housekeeping: note time, retry storage and cleanups,
    /// check if due. Everything it changes lands through `refresh`.
    private func tick() {
        Task {
            await manager.tick()
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
                self?.wakeOrNetwork()
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

    /// One line for the status menu while not simply licensed.
    var statusLine: String? {
        switch state {
        case .licensed: nil
        case .unlicensed: snapshot.storageError == nil ? "Not licensed — start a trial or buy in Settings" : "Can’t read the license from the Keychain"
        case .trial(let days): "Trial: about \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded(clockChanged: false): "Trial ended — buy in Settings"
        case .trialEnded(clockChanged: true): "Clock changed — connect to the internet to verify your trial"
        case .grace(let days, let warn): warn ? "Connect to the internet within \(days) day\(days == 1 ? "" : "s") to keep using OpenReaction" : nil
        case .checkRequired: "Connect to the internet to verify your license"
        case .revoked: "License no longer active on this Mac"
        }
    }
}
#endif
