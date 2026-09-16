import AppKit
import MacPaperCore

/// Runs the scheduled shuffle: a timer to the next due moment from the
/// last apply, re-armed after every apply, a settings change and a wake
/// (a shuffle missed while asleep happens once, on wake). Nothing runs
/// while the interval is off.
final class ShuffleEngine {
    private let model: AppModel
    private let preferences: Preferences
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        })
        observeChanges({ [preferences] in _ = preferences.shuffleInterval }, onChange: { [weak self] in self?.arm() })
        observeChanges({ [model] in _ = model.appliedState.lastApplied }, onChange: { [weak self] in self?.arm() })
        arm()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        }
    }

    /// The anchor is the later of the last apply and the last fire (a fire
    /// that could apply nothing, or shuffle being turned on with nothing
    /// applied yet): the next shuffle is one interval after it.
    var schedule: ShuffleSchedule {
        let anchor = [model.appliedState.lastApplied, lastFire].compactMap { $0 }.max()
        return ShuffleSchedule(interval: preferences.shuffleInterval, anchor: anchor)
    }

    private var lastFire: Date?

    /// The next due moment, for Settings.
    var nextDue: Date? { schedule.nextDue(now: Date()) }

    func arm() {
        timer?.invalidate()
        timer = nil
        guard preferences.shuffleInterval != .off else {
            lastFire = nil
            return
        }
        if model.appliedState.lastApplied == nil, lastFire == nil { lastFire = Date() }
        let now = Date()
        if schedule.isDue(now: now) {
            fire()
            return
        }
        guard let next = schedule.nextDue(now: now) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        // Re-armed from now at once; the apply's own `lastApplied`, a moment
        // later, re-arms again through observation.
        lastFire = Date()
        model.scheduledShuffle()
        arm()
    }
}
