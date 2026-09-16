import AppKit
import MacPaperCore

/// One-shot timers the engine arms, so tests can drive it without waiting.
protocol OneShotScheduler {
    /// Schedules `fire` at `date`; the returned token cancels it.
    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) -> any ScheduledToken
}

protocol ScheduledToken {
    func cancel()
}

/// A delay the model arms and may cancel (the live-apply debounce); the
/// tests replace it with a manual one that fires on demand.
protocol DelayScheduler {
    func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) -> any ScheduledToken
}

/// A sleeping task.
struct TaskDelayScheduler: DelayScheduler {
    private final class Token: ScheduledToken {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) -> any ScheduledToken {
        Token(Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            fire()
        })
    }
}

/// `Timer` on the main run loop, in common modes, with a 30 s tolerance.
struct TimerScheduler: OneShotScheduler {
    private final class Token: ScheduledToken {
        let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }

    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) -> any ScheduledToken {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        return Token(timer)
    }
}

/// Runs the scheduled shuffle: a timer to the next due moment, re-armed
/// after every apply and every settings change. Nothing ever fires at
/// launch or on wake: an overdue schedule (the Mac slept, the app was not
/// running) is anchored at that moment, and the next shuffle is one
/// interval later. Missed shuffles are not caught up. Nothing runs while
/// the interval is off.
final class ShuffleEngine {
    private let model: AppModel
    private let preferences: Preferences
    private let scheduler: any OneShotScheduler
    private let now: () -> Date
    private var token: (any ScheduledToken)?
    private var observers: [NSObjectProtocol] = []
    /// The moment the schedule was last anchored here (launch, wake, a
    /// fire): the next shuffle is one interval after the later of this
    /// and the last apply.
    private(set) var anchor: Date?

    init(model: AppModel, preferences: Preferences, scheduler: any OneShotScheduler = TimerScheduler(), now: @escaping () -> Date = Date.init) {
        self.model = model
        self.preferences = preferences
        self.scheduler = scheduler
        self.now = now
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        observeChanges({ [preferences] in _ = preferences.shuffleInterval }, onChange: { [weak self] in self?.settingsChanged() })
        observeChanges({ [model] in _ = model.appliedState.lastApplied }, onChange: { [weak self] in self?.arm() })
        resume()
    }

    deinit {
        MainActor.assumeIsolated {
            token?.cancel()
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        }
    }

    var schedule: ShuffleSchedule {
        let anchor = [model.appliedState.lastApplied, self.anchor].compactMap { $0 }.max()
        return ShuffleSchedule(interval: preferences.shuffleInterval, anchor: anchor)
    }

    /// The next due moment, for Settings.
    var nextDue: Date? { schedule.nextDue(now: now()) }

    /// Launch and wake: whatever was due while away is not fired; the
    /// clock restarts here.
    func resume() {
        anchor = now()
        arm()
    }

    /// The interval changed: the next shuffle is one new interval from now
    /// (a shorter interval never fires at once).
    private func settingsChanged() {
        anchor = now()
        arm()
    }

    func arm() {
        token?.cancel()
        token = nil
        guard preferences.shuffleInterval != .off else { return }
        let current = now()
        var next = schedule.nextDue(now: current) ?? current
        if next <= current {
            // Overdue (the last apply predates the anchor by more than an
            // interval): one interval from now, never now.
            anchor = current
            next = schedule.nextDue(now: current) ?? current
        }
        token = scheduler.schedule(at: next) { [weak self] in self?.fire() }
    }

    private func fire() {
        anchor = now()
        model.scheduledShuffle()
        arm()
    }
}
