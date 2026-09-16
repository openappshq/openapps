#if OPENAPPS_LICENSING
import AppKit
import Network
import OpenAppsLicensing
import SwiftUI

/// Owns the `LicenseManager` in official builds: schedules the daily check
/// and the trial's registration (launch, timers, wake, network back),
/// exposes state for the UI and tells the app whether notes may be
/// written.
///
/// The manager lives on its own actor and hands over a `LicenseSnapshot`
/// right after its memory changes, before it touches the record store. The
/// entitlement is never cached here: `state` projects the latest snapshot
/// to the clocks at the moment it is asked (the trial's monotonic clock, a
/// held clock-behind, an unchecked wake), so every consumer — the deck, a
/// keystroke, the save debounce, a close, All Notes, auto-archive — sees a deadline the
/// instant it passes, whether or not the deadline timer has fired yet. The
/// timers only wake the app up to re-render and to run the manager's
/// housekeeping. OpenNotes’ notes are written on the main actor, so
/// nothing has to be locked from the manager's thread.
@MainActor
@Observable
final class LicenseController {
    let manager: LicenseManager
    private(set) var snapshot: LicenseSnapshot
    private(set) var isBusy = false
    private(set) var message: LicenseMessage?
    /// A key from a deep link, waiting for the user's confirmation.
    var pendingKey: String?
    /// Runs whenever the state may have changed (the feature on/off, badge).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var checkTimer: Timer?
    /// Fires at the next local entitlement change (a trial day boundary or
    /// its end, grace warning or end), independent of the network schedule.
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied = true

    /// What `onChange` last reported; compared against, not the snapshot
    /// that was just replaced, so a change in the badge alone (a storage
    /// error while the state stays the same) reaches the app too.
    private struct Published: Equatable {
        var state: LicenseState
        var badge: LicenseBadge.Label?
        var freshInstall: Bool?
    }
    @ObservationIgnored private var published: Published

    /// The clocks the projection uses; the app passes the real ones, and
    /// they must be the manager's, so both sides see the same time.
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uptime: () -> TimeInterval

    /// Until the manager has loaded, there is no record: the feature is off.
    init(manager: LicenseManager, now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = LicenseManager.continuousUptime) {
        self.manager = manager
        self.now = now
        self.uptime = uptime
        let initial = LicenseSnapshot(trialTiming: manager.trialTiming)
        let initialState = initial.state(now: now(), uptime: uptime())
        snapshot = initial
        published = Published(state: initialState, badge: LicenseBadge.label(for: initialState, appName: Licensing.appName), freshInstall: nil)
    }

    /// Wires the snapshot feed (the manager's actor to the main actor), then
    /// loads storage on the license actor.
    private func subscribe() async {
        await manager.setOnChange { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(snapshot) }
            }
        }
        await manager.load()
    }

    private func receive(_ snapshot: LicenseSnapshot) {
        self.snapshot = snapshot
        // The manager has checked the clock since the wake: its snapshot decides.
        if let pendingWake, (snapshot.trialClock?.lastBehindCheck ?? .infinity) >= pendingWake {
            self.pendingWake = nil
        }
        refresh()
    }

    /// The monotonic time of a wake the manager has not checked yet; until
    /// it has, the clock-behind check is projected here, before any I/O.
    @ObservationIgnored private var pendingWake: TimeInterval?

    /// The entitlement now: the latest snapshot projected to the current
    /// clocks. Reading `snapshot` registers observation, so an observer
    /// re-evaluates when the manager publishes; the clocks it does not
    /// observe, which is what `publish`/the timers are for.
    var state: LicenseState {
        snapshot.state(now: now(), uptime: uptime(), wakeSince: pendingWake)
    }

    /// Whether notes may be written right now (LICENSING.md: the core
    /// feature; off means read-only). Never cached: the model and the store
    /// ask at every action and at the file, the views on every body.
    var isFeatureEnabled: Bool { state.isFeatureEnabled }

    var storageError: LicenseStoreError? { snapshot.storageError }
    var trialStorageError: LicenseStoreError? { snapshot.trialStorageError }
    var journalError: Bool { snapshot.journalError }
    /// The install has never run with licensing (both record files
    /// positively absent); nil until storage has answered. See
    /// `LicenseManager.freshInstall`.
    var freshInstall: Bool? { snapshot.freshInstall }

    func start() {
        // Storage, the provisional trial and the launch check run on the
        // license actor; nothing here waits for them.
        Task { await attach() }
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
        pathMonitor.start(queue: DispatchQueue(label: "space.openapps.opennotes.license.network"))
    }

    /// Reads storage and runs the launch check on the license actor; the
    /// snapshot feed is live from the first read. `start` calls it; tests
    /// call it directly, without the timers and system observers.
    func attach() async {
        await subscribe()
        await manager.checkOnLaunch()
        refresh()
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
    /// Waits at most `quitSaveBound`: a stuck disk never holds up Quit,
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

    private nonisolated final class ResumeOnce: @unchecked Sendable {
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

    /// Wake from sleep: the clock-behind check is projected from the snapshot
    /// at once, on the main actor, then the manager observes the wake.
    private func didWake() {
        pendingWake = uptime()
        refresh()
        Task {
            await manager.wake()
            refresh()
        }
    }

    /// The network back: an unregistered trial asks the registry now.
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
        // Keyed off the projected trial clock (monotonic time), or the paid
        // license's wall-clock deadline.
        if let delay = snapshot.deadlineDelay(now: now(), uptime: uptime(), wakeSince: pendingWake) {
            deadlineTimer = makeTimer(after: delay + 1) { [weak self] in
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

    /// Re-arms both timers from the snapshot and the clock — never from
    /// storage — and tells the app when what it shows may have changed.
    /// Cheap; called on every timer and event. Not an authorisation step:
    /// `state` is projected afresh by whoever asks.
    private func refresh() {
        scheduleTimers()
        let current = Published(state: state, badge: badge, freshInstall: freshInstall)
        if current != published {
            published = current
            onChange?()
        }
    }

    // MARK: - Copy

    static let clockBehindText = "Your Mac’s clock is behind. Set the correct date and time to keep using your free trial"

    /// "Free trial: N days left", or "less than a day left" on the last day.
    static func trialText(daysLeft days: Int) -> String {
        days <= 1 ? "Free trial: less than a day left" : "Free trial: \(days) days left"
    }

    /// The pill on the open note, in All Notes' toolbar and the settings
    /// title bar, while not simply licensed. The end of the trial is said
    /// here, by All Notes' card and the note's footer; nothing opens on its own.
    var badge: LicenseBadge.Label? {
        LicenseBadge.label(
            for: state,
            appName: Licensing.appName,
            storageError: snapshot.storageError != nil,
            trialStorageError: snapshot.trialStorageError != nil
        )
    }

    /// The card (All Notes) and the notice (the note's footer) while
    /// read-only; nil while writing is allowed.
    var restriction: LicenseRestriction? {
        LicenseRestriction.card(
            for: state,
            storageError: snapshot.storageError != nil,
            trialStorageError: snapshot.trialStorageError != nil
        )
    }
}
#endif
