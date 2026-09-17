import XCTest
@testable import OpenNotes
import OpenNotesCore

/// A tick source driven by hand: nothing fires until `step()`.
final class ManualTickScheduler: EdgeHoldTickScheduler {
    private final class Token: EdgeHoldTickToken {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private var ticks: [(Token, @MainActor () -> Void)] = []

    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> any EdgeHoldTickToken {
        let token = Token()
        ticks.append((token, tick))
        return token
    }

    /// Fires every uncancelled tick once, in order.
    @MainActor func step() {
        for (token, tick) in ticks where !token.cancelled { tick() }
    }
}

/// The edge-hold timer the deck view owns: started as the lifted tab is
/// judged to be at an end — at the lift itself, or on a move — it scrolls
/// the fan every tick until stopped.
final class EdgeHoldTimerTests: XCTestCase {
    @MainActor func testAHoldStartedScrollsOnEveryTickUntilEnded() {
        let scheduler = ManualTickScheduler()
        let timer = EdgeHoldTimer(scheduler: scheduler)
        var deltas: [CGFloat] = []
        timer.moved(to: .down, onScroll: { deltas.append($0) })
        XCTAssertTrue(timer.isHolding)
        scheduler.step()
        scheduler.step()
        scheduler.step()
        XCTAssertEqual(deltas.count, 3, "one delta per tick")
        XCTAssertTrue(deltas.allSatisfy { $0 == DeckAutoScroll.step })
        timer.end()
        XCTAssertFalse(timer.isHolding)
        let ticked = deltas.count
        scheduler.step()
        XCTAssertEqual(deltas.count, ticked, "nothing after the end")
    }

    @MainActor func testAHoldTheOtherWayRestartsAndNilStops() {
        let scheduler = ManualTickScheduler()
        let timer = EdgeHoldTimer(scheduler: scheduler)
        var deltas: [CGFloat] = []
        timer.moved(to: .up, onScroll: { deltas.append($0) })
        scheduler.step()
        scheduler.step()
        scheduler.step()
        XCTAssertTrue(deltas.allSatisfy { $0 == -DeckAutoScroll.step })
        timer.moved(to: .down, onScroll: { deltas.append($0) })
        scheduler.step()
        XCTAssertEqual(deltas.last, DeckAutoScroll.step)
        timer.moved(to: nil, onScroll: { deltas.append($0) })
        XCTAssertFalse(timer.isHolding)
        let ticked = deltas.count
        scheduler.step()
        XCTAssertEqual(deltas.count, ticked)
    }
}
