import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// The engine over a fake clock and a recording scheduler: what gets
/// armed, and that nothing ever fires at launch or on wake.
@MainActor
struct ShuffleEngineTests {
    final class FakeScheduler: OneShotScheduler {
        final class Token: ScheduledToken {
            var cancelled = false
            let date: Date
            let fire: @MainActor () -> Void
            init(date: Date, fire: @escaping @MainActor () -> Void) { self.date = date; self.fire = fire }
            func cancel() { cancelled = true }
        }
        var tokens: [Token] = []
        var live: Token? { tokens.last(where: { !$0.cancelled }) }
        func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) -> any ScheduledToken {
            let token = Token(date: date, fire: fire)
            tokens.append(token)
            return token
        }
    }

    /// Starts at the real now: the model stamps applies with `Date()`, and
    /// the engine anchors on the later of the two.
    final class Clock {
        var now = Date()
    }

    /// Observation callbacks land on the main queue asynchronously.
    func settle() async {
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("An overdue schedule at launch is armed one interval from now, never fired")
    func overdueAtLaunch() throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        let clock = Clock()
        let scheduler = FakeScheduler()
        h.preferences.shuffleInterval = .hour1
        try h.model.applied.update { $0.lastApplied = clock.now.addingTimeInterval(-10 * 3600) }
        h.model.reloadAppliedState()
        let engine = ShuffleEngine(model: h.model, preferences: h.preferences, scheduler: scheduler, now: { clock.now })
        #expect(h.desktop.calls.isEmpty, "nothing applied at launch")
        #expect(scheduler.live?.date == clock.now.addingTimeInterval(3600))
        #expect(engine.nextDue == clock.now.addingTimeInterval(3600))
    }

    @Test("Off arms nothing; turning it on arms one interval from now; a shorter interval never fires at once")
    func settings() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        let clock = Clock()
        let scheduler = FakeScheduler()
        let engine = ShuffleEngine(model: h.model, preferences: h.preferences, scheduler: scheduler, now: { clock.now })
        #expect(scheduler.live == nil && engine.nextDue == nil)
        h.preferences.shuffleInterval = .hours3
        await settle()
        #expect(scheduler.live?.date == clock.now.addingTimeInterval(3 * 3600))
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        h.preferences.shuffleInterval = .minutes15
        await settle()
        #expect(scheduler.live?.date == clock.now.addingTimeInterval(900), "from the change, not from the old anchor")
        #expect(h.desktop.calls.isEmpty)
        h.preferences.shuffleInterval = .off
        await settle()
        #expect(scheduler.live == nil)
    }

    @Test("A fire shuffles and re-arms; wake re-anchors without firing")
    func fireAndWake() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        let clock = Clock()
        let scheduler = FakeScheduler()
        h.preferences.shuffleInterval = .minutes15
        let engine = ShuffleEngine(model: h.model, preferences: h.preferences, scheduler: scheduler, now: { clock.now })
        let first = scheduler.live!
        clock.now = first.date
        first.fire()
        await h.settle()
        await settle()
        #expect(h.desktop.calls.count == 2, "both displays")
        // Re-armed one interval after the fire.
        #expect(scheduler.live?.date == clock.now.addingTimeInterval(900))
        // Asleep through three intervals, then wake: no fire, one interval from the wake.
        clock.now = Date().addingTimeInterval(3000)
        engine.resume()
        await h.settle()
        #expect(h.desktop.calls.count == 2)
        #expect(scheduler.live?.date == clock.now.addingTimeInterval(900))
    }
}
