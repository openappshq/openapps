import XCTest
@testable import OpenNotes
import OpenNotesCore

/// The edge-hold timer the deck view owns: started as the lifted tab is
/// judged to be at an end — at the lift itself, or on a move — it scrolls
/// the fan every tick until stopped.
final class EdgeHoldTimerTests: XCTestCase {
    @MainActor func testAHoldStartedScrollsOnEveryTickUntilEnded() {
        let timer = EdgeHoldTimer()
        var deltas: [CGFloat] = []
        timer.moved(to: .down, onScroll: { deltas.append($0) })
        XCTAssertTrue(timer.isHolding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThanOrEqual(deltas.count, 2, "several ticks in 100 ms")
        XCTAssertTrue(deltas.allSatisfy { $0 == DeckAutoScroll.step })
        timer.end()
        XCTAssertFalse(timer.isHolding)
        let ticked = deltas.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(deltas.count, ticked, "nothing after the end")
    }

    @MainActor func testAHoldTheOtherWayRestartsAndNilStops() {
        let timer = EdgeHoldTimer()
        var deltas: [CGFloat] = []
        timer.moved(to: .up, onScroll: { deltas.append($0) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(deltas.allSatisfy { $0 == -DeckAutoScroll.step })
        timer.moved(to: .down, onScroll: { deltas.append($0) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(deltas.last, DeckAutoScroll.step)
        timer.moved(to: nil, onScroll: { deltas.append($0) })
        XCTAssertFalse(timer.isHolding)
        let ticked = deltas.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(deltas.count, ticked)
    }
}
