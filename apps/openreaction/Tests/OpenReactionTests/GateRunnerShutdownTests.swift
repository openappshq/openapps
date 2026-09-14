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
        /// What happened when a replay actually ran.
        enum Run: Equatable { case posted(Int), dropped(Int) }
        private let lock = NSLock()
        private var _ops: [Op] = []
        private var _runs: [Run] = []
        private var queue: [@Sendable () -> Void] = []
        var failsFlushes = false

        var ops: [Op] { lock.withLock { _ops } }
        var runs: [Run] { lock.withLock { _runs } }

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

        func replay(_ events: [CGEvent], guard: ReplayGuard?, completion: (@Sendable () -> Void)?) {
            let count = events.count
            enqueue(count == 0 && completion != nil ? .confirm : .replay(count)) { [self] in
                if count > 0 {
                    let posted = `guard`?.shouldPost() ?? true
                    lock.withLock { _runs.append(posted ? .posted(count) : .dropped(count)) }
                    if !posted { `guard`?.dropped(count) }
                }
                completion?()
            }
        }

        func repost(keyCode: UInt16) {}
    }

    /// The main actor's side: records effects; the test answers destination
    /// checks the way the app layer's focus lookup would.
    final class MainRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _effects: [GateRunner.MainEffect] = []
        var effects: [GateRunner.MainEffect] { lock.withLock { _effects } }
        func append(_ effects: [GateRunner.MainEffect]) { lock.withLock { _effects += effects } }

        var destinationChecks: [(transaction: Int, target: FocusTarget)] {
            effects.compactMap { if case .checkDestination(let t, let target) = $0 { return (t, target) } else { return nil } }
        }

        var lostInput: [Int] {
            effects.compactMap { if case .inputLost(let count) = $0 { return count } else { return nil } }
        }
    }

    struct Fixture {
        static let field = FocusTarget(pid: 1, element: 1)
        let poster = FakePoster()
        let main = MainRecorder()
        let runner: GateRunner

        init() {
            let main = self.main
            runner = GateRunner(gate: InputGate(), poster: poster) { main.append($0) }
            runner.focusTracking(active: true)
            runner.probeResult(generation: 0, tokenID: nil, .editable(anchor: .zero, target: Self.field))
        }

        /// The fake focus lookup: answers the latest destination check.
        func answerDestination(focusedOn target: FocusTarget? = Fixture.field) {
            guard let check = main.destinationChecks.last else { return }
            runner.destinationChecked(transaction: check.transaction, matches: target == check.target)
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

        // macOS disabled the tap: the colon is replayed, best effort — once
        // the focus is confirmed to still be the field it was typed in.
        fixture.runner.tapInterrupted()
        #expect(fixture.poster.ops == [.flush(1)])
        #expect(fixture.main.destinationChecks.last?.target == Fixture.field)
        fixture.answerDestination()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        // A fresh Backspace while that replay is only enqueued: held, not passed.
        #expect(fixture.key(KeyCode.delete) == .hold)
        #expect(fixture.key(KeyCode.delete, down: false) == .hold)
        #expect(!fixture.runner.isIdle)

        // The queue runs the replay: only now does the Backspace go out, after
        // it, and only after its own destination check.
        fixture.poster.runQueue()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        fixture.answerDestination()
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
        fixture.answerDestination()
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
        fixture.runner.flushAck(transaction: 1) // the drain confirms the field first
        #expect(fixture.poster.ops == [.flush(1)])
        #expect(fixture.main.destinationChecks.last?.target == Fixture.field)
        fixture.answerDestination() // then replays, with a flush behind
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .flush(1)])
        #expect(!fixture.runner.isIdle)
        fixture.runner.flushAck(transaction: 1)
        #expect(await fixture.runner.waitForShutdown() == .delivered)
        fixture.poster.runQueue()
        #expect(fixture.poster.runs == [.posted(1)])
    }

    // MARK: Round 7 — acknowledged drains are checked too

    @Test func anAcknowledgedShutdownDrainNeverReplaysIntoAChangedField() async {
        // holdColonAndBeginShutdown → focusMayHaveMoved → flushAck → runQueue
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        fixture.runner.focusMayHaveMoved() // app A moved focus to field B
        fixture.runner.flushAck(transaction: 1)
        fixture.answerDestination(focusedOn: FocusTarget(pid: 7, element: 9)) // the lookup finds B
        fixture.poster.runQueue()
        #expect(fixture.poster.ops == [.flush(1)]) // nothing was ever enqueued for replay
        #expect(fixture.poster.runs.isEmpty)
        #expect(!fixture.runner.isIdle) // the colon is kept for the field or the user
        #expect(fixture.main.effects.contains { if case .destinationChanged = $0 { return true } else { return false } })
        // The field comes back: replayed there, acknowledged, delivered.
        fixture.runner.focusMayHaveMoved()
        fixture.answerDestination()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .flush(1)])
        fixture.poster.runQueue()
        #expect(fixture.poster.runs == [.posted(1)])
        fixture.runner.flushAck(transaction: 1)
        #expect(await fixture.runner.waitForShutdown() == .delivered)
    }

    @Test func aFocusChangeBetweenAnApprovedDrainAndItsExecutionDropsIt() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        fixture.runner.flushAck(transaction: 1)
        fixture.answerDestination() // approved and enqueued
        fixture.runner.focusMayHaveMoved() // ... but focus moves before the queue runs
        fixture.poster.runQueue()
        #expect(fixture.poster.runs == [.dropped(1)])
        #expect(fixture.main.lostInput == [1])
        fixture.runner.flushAck(transaction: 1) // the flush behind it still comes back
        #expect(await fixture.runner.waitForShutdown() == .delivered)
    }

    @Test func discardingCancelsReplaysAlreadyOnTheQueue() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        fixture.runner.tapInterrupted()
        fixture.answerDestination() // approved: replay enqueued, not run
        #expect(fixture.key(KeyCode.delete) == .hold)
        fixture.runner.discardHeldInput()
        fixture.poster.runQueue()
        #expect(fixture.poster.runs == [.dropped(1)]) // the queued colon never posts
        #expect(fixture.runner.isIdle)
    }

    @Test func aStreamThatNeverAnswersReplaysAtTheBoundAndEndsOnlyOnceThatRan() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let stop = Task {
            await fixture.runner.awaitShutdown(acknowledgementBound: .milliseconds(50), replayBound: .seconds(5)) {}
        }
        // The acknowledgement bound passes: the colon is replayed in order,
        // best effort, with the tap still installed.
        while fixture.main.destinationChecks.isEmpty { await Task.yield() }
        fixture.answerDestination()
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        #expect(!fixture.runner.isIdle)
        #expect(!stop.isCancelled)
        // Physical input after the bound: held behind the queued replay.
        #expect(fixture.key(KeyCode.delete) == .hold)
        #expect(fixture.key(KeyCode.delete, down: false) == .hold)
        // The replay runs; the Backspace follows it; its own replay must run too.
        fixture.poster.runQueue()
        fixture.answerDestination()
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

    @Test func aPostingQueueThatDoesNotRunTheReplayKeepsOwnershipAndIsReported() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let stuck = Stuck()
        let stop = Task {
            await fixture.runner.awaitShutdown(acknowledgementBound: .milliseconds(20), replayBound: .milliseconds(50)) { stuck.fire() }
        }
        while fixture.main.destinationChecks.isEmpty { await Task.yield() }
        fixture.answerDestination()
        // The replay bound passes with the queue idle: the app layer is told,
        // and nothing else happens — no outcome, the tap still owns the stream.
        while !stuck.fired { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!fixture.runner.isIdle)
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm]) // enqueued, not run
        #expect(fixture.key(KeyCode.delete) == .hold) // still held behind the replay
        // Only the queue running the replay ends the stop (quit is approved after this).
        fixture.poster.runQueue()
        fixture.answerDestination()
        fixture.poster.runQueue()
        #expect(await stop.value == .failed)
        #expect(fixture.runner.isIdle)
    }

    final class Stuck: @unchecked Sendable {
        private(set) var fired = false
        func fire() { fired = true }
    }

    @Test func aDelayedReplayIntoAChangedFieldIsDroppedAndReported() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let waiter = Task { await fixture.runner.waitForShutdown() }
        await Task.yield()
        fixture.runner.tapInterrupted()
        // The focus lookup finds another field (or a password field): the
        // held colon is not posted anywhere; it waits for the field or the user.
        fixture.answerDestination(focusedOn: FocusTarget(pid: 7, element: 9))
        #expect(fixture.poster.ops == [.flush(1)])
        #expect(fixture.main.effects.contains { if case .destinationChanged = $0 { return true } else { return false } })
        #expect(fixture.main.lostInput.isEmpty)
        #expect(!fixture.runner.isIdle)
        // The user discards it.
        fixture.runner.discardHeldInput()
        #expect(fixture.main.lostInput == [1])
        #expect(await waiter.value == .failed)
        #expect(fixture.runner.isIdle)
    }

    // MARK: G4 — the destination is checked again when the replay runs

    @Test func aFocusChangeAfterApprovalDropsTheQueuedReplayWhenItRuns() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let waiter = Task { await fixture.runner.waitForShutdown() }
        await Task.yield()
        fixture.runner.tapInterrupted()
        fixture.answerDestination() // approved: replay queued
        #expect(fixture.poster.ops == [.flush(1), .replay(1), .confirm])
        // Focus moves before the queue gets to it (the focus monitor keeps
        // reporting during a shutdown).
        fixture.runner.focusMayHaveMoved()
        fixture.poster.runQueue()
        #expect(fixture.poster.runs == [.dropped(1)])
        #expect(fixture.main.lostInput == [1])
        #expect(await waiter.value == .interrupted)
        // Without a focus change the same replay is posted.
        let steady = Fixture()
        steady.holdColonAndBeginShutdown()
        steady.runner.tapInterrupted()
        steady.answerDestination()
        steady.poster.runQueue()
        #expect(steady.poster.runs == [.posted(1)])
        #expect(steady.main.lostInput.isEmpty)
    }

    @Test func aFocusChangeWhileTheDestinationIsBeingLookedUpCountsAsChanged() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        fixture.runner.tapInterrupted()
        #expect(fixture.main.destinationChecks.count == 1)
        fixture.runner.focusMayHaveMoved() // between the question and the answer
        fixture.answerDestination() // the lookup still says the original field
        #expect(fixture.poster.ops == [.flush(1)]) // nothing replayed on a stale answer
        // Asked again instead; this lookup finds another field: kept.
        #expect(fixture.main.destinationChecks.count == 2)
        fixture.answerDestination(focusedOn: FocusTarget(pid: 7, element: 9))
        #expect(fixture.poster.ops == [.flush(1)])
        #expect(fixture.main.effects.contains { if case .destinationChanged = $0 { return true } else { return false } })
        #expect(!fixture.runner.isIdle)
    }

    // MARK: G5 — own windows stay usable; discarding is the user's choice

    @Test func inputAimedAtOurOwnWindowsPassesWhileShuttingDown() {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        fixture.runner.tapInterrupted()
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        #expect(fixture.runner.mouse(.down, at: .zero, event: click, targetsOwnApp: true) == .pass)
        #expect(fixture.runner.mouse(.down, at: .zero, event: click, targetsOwnApp: false) == .hold)
        let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.return), keyDown: true)!
        #expect(fixture.runner.key(keyCode: KeyCode.return, isDown: true, isRepeat: false, modifiers: [], secureInput: false, event: key, targetsOwnApp: true) { "" } == .pass)
        #expect(fixture.key(KeyCode.return) == .hold)
    }

    @Test func discardingHeldInputEndsAStuckStopWithoutTheQueue() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let stuck = Stuck()
        let stop = Task {
            await fixture.runner.awaitShutdown(acknowledgementBound: .milliseconds(20), replayBound: .milliseconds(40)) { stuck.fire() }
        }
        while fixture.main.destinationChecks.isEmpty { await Task.yield() }
        fixture.answerDestination()
        while !stuck.fired { await Task.yield() }
        #expect(fixture.key(KeyCode.delete) == .hold)
        // The user clicks "Discard held typing".
        fixture.runner.discardHeldInput()
        #expect(await stop.value == .failed)
        #expect(fixture.runner.isIdle)
        #expect(fixture.main.lostInput == [1]) // the Backspace held after the replay was queued
    }

    @Test func anAcknowledgementThatArrivesInTimeIsDelivered() async {
        let fixture = Fixture()
        fixture.holdColonAndBeginShutdown()
        let stop = Task {
            await fixture.runner.awaitShutdown(acknowledgementBound: .seconds(5), replayBound: .seconds(5)) {}
        }
        await Task.yield()
        fixture.runner.flushAck(transaction: 1)
        fixture.answerDestination()
        fixture.runner.flushAck(transaction: 1)
        #expect(await stop.value == .delivered)
    }
}
