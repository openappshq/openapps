import CoreGraphics
import Foundation
import OpenReactionCore
import Testing
@testable import OpenReaction

/// The runner's shutdown protocol against a recording poster: nothing is
/// posted to the session. The poster's queue runs only when the test says
/// so, the way the real serial insertion queue runs later than the enqueue.
@Suite("Gate runner shutdown", .serialized)
struct GateRunnerShutdownTests {
    /// Records what the runner asked to post, in order, and holds the queued
    /// work until `runQueue`.
    final class FakePoster: EventPoster, @unchecked Sendable {
        enum Op: Equatable { case flush(Int), replay(Int), confirm, replacement(Int) }
        private let lock = NSLock()
        private var _ops: [Op] = []
        private var queue: [@Sendable () -> Void] = []
        var failsFlushes = false

        var ops: [Op] { lock.withLock { _ops } }

        private func enqueue(_ op: Op, _ work: @escaping @Sendable () -> Void) {
            lock.withLock {
                _ops.append(op)
                queue.append(work)
            }
        }

        /// Runs what was enqueued before this call, in order, outside any
        /// lock; work enqueued by that work waits for the next call.
        func runQueue() {
            let batch = lock.withLock { () -> [@Sendable () -> Void] in
                let batch = queue
                queue = []
                return batch
            }
            for work in batch { work() }
        }

        func postReplacement(transaction: Int, deleteCount: Int, text: String, commit: @escaping @Sendable () -> Bool, onFailure: @escaping @Sendable () -> Void) {
            enqueue(.replacement(transaction)) { [self] in
                guard commit() else { return }
                if failsFlushes { onFailure() }
            }
        }

        func postFlush(transaction: Int, onFailure: @escaping @Sendable () -> Void) {
            enqueue(.flush(transaction)) { [self] in
                if failsFlushes { onFailure() }
            }
        }

        func replay(_ events: [CGEvent], completion: (@Sendable () -> Void)?) {
            enqueue(events.isEmpty && completion != nil ? .confirm : .replay(events.count)) { completion?() }
        }

        func repost(keyCode: UInt16) {}
    }

    struct Fixture {
        let poster = FakePoster()
        let runner: GateRunner

        init() {
            runner = GateRunner(gate: InputGate(), poster: poster) { _ in }
            runner.focusTracking(active: true)
            // The probe request went to the (ignored) main handler; answer generation 0.
            runner.probeResult(generation: 0, tokenID: nil, .editable(anchor: .zero, target: FocusTarget(pid: 1, element: 1)))
        }

        @discardableResult
        func key(_ keyCode: UInt16, _ text: String = "", shift: Bool = false, down: Bool = true) -> InputGate.KeyDecision {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down)!
            return runner.key(keyCode: keyCode, isDown: down, isRepeat: false, modifiers: shift ? .shift : [], secureInput: false, event: event) { text }
        }

        /// Holds a colon (its token probe never answered), then begins the shutdown.
        func holdColonAndBeginShutdown() {
            #expect(key(41, ":", shift: true) == .hold)
            #expect(runner.capturesText)
            runner.beginShutdown()
            #expect(poster.ops == [.flush(1)]) // the cancelled probe's flush
            #expect(!runner.isIdle)
        }
    }

    @Test func interruptionEndsOnlyAfterTheReplayRanAndFreshInputFollowsIt() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let waiter = Task { await fixture.runner.waitForShutdown() }
        await Task.yield()

        // macOS disabled the tap: the colon is replayed, best effort.
        fixture.runner.tapInterrupted()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        // A fresh Backspace while that replay is only enqueued: held, not passed.
        #expect(fixture.key(KeyCode.delete) == .hold)
        #expect(fixture.key(KeyCode.delete, down: false) == .hold)
        #expect(!fixture.runner.isIdle)

        // The queue runs the replay: only now does the Backspace go out, after it.
        fixture.poster.runQueue()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm, .replay(2), .confirm])
        #expect(!fixture.runner.isIdle)
        #expect(!waiter.isCancelled)

        // And its replay has to run before the shutdown is over.
        fixture.poster.runQueue()
        #expect(fixture.runner.isIdle)
        #expect(await waiter.value == .interrupted)
    }

    @Test func aFlushThatCannotBePostedEndsTheShutdownAsFailedAfterTheReplay() async {
        let fixture = Fixture()
        fixture.poster.failsFlushes = true
        fixture.holdColonAndBeginShutdown()
        let waiter = Task { await fixture.runner.waitForShutdown() }
        await Task.yield()

        // The queue runs the flush: the marker cannot be made.
        fixture.poster.runQueue()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        #expect(!fixture.runner.isIdle)
        fixture.poster.runQueue()
        #expect(fixture.runner.isIdle)
        #expect(await waiter.value == .failed)
    }

    @Test func aShutdownWithNothingOwedIsDelivered() async {
        let fixture = Fixture()
        fixture.runner.beginShutdown()
        #expect(await fixture.runner.waitForShutdown() == .delivered)
    }

    @Test func anAcknowledgedDrainIsDelivered() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        fixture.runner.flushAck(transaction: 1) // replay + flush
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .flush(1)])
        #expect(!fixture.runner.isIdle)
        fixture.runner.flushAck(transaction: 1)
        #expect(await fixture.runner.waitForShutdown() == .delivered)
    }

    @Test func aStreamThatNeverAnswersReplaysAtTheBoundAndEndsOnlyOnceThatRan() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let stop = Task {
            await fixture.runner.awaitShutdown(acknowledgementBound: .milliseconds(50), replayBound: .seconds(5))
        }
        // The acknowledgement bound passes: the colon is replayed in order,
        // best effort, with the tap still installed.
        while fixture.poster.ops.count < 3 { await Task.yield() }
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        #expect(!fixture.runner.isIdle)
        #expect(!stop.isCancelled)
        // Physical input after the bound: held behind the queued replay.
        #expect(fixture.key(KeyCode.delete) == .hold)
        #expect(fixture.key(KeyCode.delete, down: false) == .hold)
        // The replay runs; the Backspace follows it; its own replay must run too.
        fixture.poster.runQueue()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm, .replay(2), .confirm])
        #expect(!fixture.runner.isIdle)
        fixture.poster.runQueue()
        #expect(await stop.value == .failed)
        #expect(fixture.runner.isIdle)
        // Nothing is left for the tap's removal to let out.
        let before = fixture.poster.ops.count
        fixture.runner.tapStopped()
        #expect(fixture.poster.ops.count == before)
    }

    @Test func aPostingQueueThatNeverRunsTheReplayIsAbandoned() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let outcome = await fixture.runner.awaitShutdown(acknowledgementBound: .milliseconds(20), replayBound: .milliseconds(50))
        #expect(outcome == .abandoned)
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm]) // enqueued, never run
        #expect(!fixture.runner.isIdle)
    }

    @Test func anAcknowledgementThatArrivesInTimeIsDelivered() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let stop = Task {
            await fixture.runner.awaitShutdown(acknowledgementBound: .seconds(5), replayBound: .seconds(5))
        }
        await Task.yield()
        fixture.runner.flushAck(transaction: 1)
        fixture.runner.flushAck(transaction: 1)
        #expect(await stop.value == .delivered)
    }
}
