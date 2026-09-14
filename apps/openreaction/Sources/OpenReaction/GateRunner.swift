import AppKit
import Carbon.HIToolbox
import CoreGraphics
import OpenReactionCore
import os

/// Owns the `InputGate` and feeds it an ordered stream of inputs from the tap
/// thread and the main thread under one lock, then carries out its effects.
///
/// Effects that post events go to the insertion queue *while the lock is
/// held*, so their order matches the order the gate decided them in. Effects
/// that touch UI or Accessibility are handed to the main actor.
final class GateRunner: @unchecked Sendable {
    /// Effects the main actor carries out (picker, probes, verification, timers).
    enum MainEffect: Sendable {
        case requestProbe(generation: Int, tokenID: Int?)
        case presentPicker(query: String, anchor: CGRect)
        case dismissPicker
        case moveSelection(by: Int)
        case beginInsertion(transaction: Int, source: InsertionSource, typed: String, target: FocusTarget)
        case armWatchdog(transaction: Int)
        case transactionEnded(transaction: Int, recordUse: Bool)
    }

    private struct HeldCopy: @unchecked Sendable {
        let event: CGEvent
    }

    /// Lets the lazy decoder cross into the lock's closure. It is only ever
    /// called synchronously, on the calling thread, while the lock is held.
    private final class Decoder: @unchecked Sendable {
        let decode: () -> String
        init(_ decode: @escaping () -> String) { self.decode = decode }
    }

    private struct State: Sendable {
        var gate: InputGate
        var held: [Int: HeldCopy] = [:]
        var nextEventID = 0
        /// Picker frame in Quartz coordinates while it is visible.
        var pickerFrame = CGRect.null
        /// Shutdowns waiting for their outcome, by waiter token.
        var shutdownWaiters: [Int: CheckedContinuation<InputGate.ShutdownOutcome, Never>] = [:]
        var nextWaiterToken = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let poster: any EventPoster
    private let mainHandler: @Sendable ([MainEffect]) -> Void

    init(gate: InputGate, poster: any EventPoster = LiveEventPoster(), mainHandler: @escaping @Sendable ([MainEffect]) -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(gate: gate))
        self.poster = poster
        self.mainHandler = mainHandler
    }

    // MARK: - Tap thread inputs

    func key(
        keyCode: UInt16, isDown: Bool, isRepeat: Bool, modifiers: KeyModifiers, secureInput: Bool,
        event: CGEvent, text: () -> String
    ) -> InputGate.KeyDecision {
        let copy = HeldCopy(event: event.copy() ?? event)
        return withoutActuallyEscaping(text) { text in
            let decoder = Decoder(text)
            return state.withLock { state in
                state.nextEventID += 1
                let id = state.nextEventID
                let keyEvent = KeyEvent(keyCode: keyCode, isDown: isDown, isRepeat: isRepeat, modifiers: modifiers, secureInput: secureInput, id: id)
                let result = state.gate.key(keyEvent, text: decoder.decode)
                if result.decision == .hold {
                    state.held[id] = copy
                }
                dispatch(result.effects, state: &state)
                return result.decision
            }
        }
    }

    func mouse(_ kind: MouseEventKind, at location: CGPoint, event: CGEvent) -> InputGate.KeyDecision {
        let copy = HeldCopy(event: event.copy() ?? event)
        return state.withLock { state in
            state.nextEventID += 1
            let id = state.nextEventID
            let onPicker = state.gate.isPickerVisible && state.pickerFrame.contains(location)
            let result = state.gate.mouse(kind, id: id, onPicker: onPicker)
            if result.decision == .hold {
                state.held[id] = copy
            }
            dispatch(result.effects, state: &state)
            return result.decision
        }
    }

    func flushAck(transaction id: Int) {
        state.withLock { state in
            let held = state.held
            dispatch(state.gate.flushAck(transaction: id, decode: { Self.text(of: held[$0]) }), state: &state)
        }
    }

    /// Characters a held key event would type, read only when the gate has
    /// decided the field is safe.
    private static func text(of copy: HeldCopy?) -> String {
        guard let copy else { return "" }
        return KeyboardTap.typedText(copy.event)
    }

    /// The system disabled and re-enabled the tap; the stream is still alive.
    func tapInterrupted() {
        state.withLock { state in
            dispatch(state.gate.tapInterrupted(), state: &state)
        }
    }

    /// A deliberate stop is coming: stop authorizing, keep draining.
    func beginShutdown() {
        state.withLock { state in
            dispatch(state.gate.beginShutdown(), state: &state)
        }
    }

    /// Nothing is held or in flight in the gate.
    var isIdle: Bool {
        state.withLock { !$0.gate.isHolding }
    }

    /// The outcome of a shutdown begun with `beginShutdown`, once the gate
    /// has nothing left to wait for: `.delivered` after the tap acknowledged
    /// everything, `.interrupted` or `.failed` once a best-effort replay has
    /// actually run on the posting queue. Never resumes on enqueued work.
    /// With a `bound`, the wait ends as `.failed` once it passes with no
    /// outcome — never as delivery.
    func waitForShutdown(bound: Duration? = nil) async -> InputGate.ShutdownOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<InputGate.ShutdownOutcome, Never>) in
            let (outcome, token) = state.withLock { state -> (InputGate.ShutdownOutcome?, Int) in
                if let outcome = state.gate.shutdownOutcome { return (outcome, 0) }
                state.nextWaiterToken += 1
                state.shutdownWaiters[state.nextWaiterToken] = continuation
                return (nil, state.nextWaiterToken)
            }
            if let outcome {
                continuation.resume(returning: outcome)
                return
            }
            guard let bound else { return }
            Task { [state] in
                try? await Task.sleep(for: bound)
                let waiter = state.withLock { $0.shutdownWaiters.removeValue(forKey: token) }
                waiter?.resume(returning: .failed)
            }
        }
    }

    /// A flush could not be posted: the gate will never see its acknowledgement.
    private func streamFailed(transaction id: Int) {
        state.withLock { state in dispatch(state.gate.streamFailed(transaction: id), state: &state) }
    }

    /// The posting queue ran every replay enqueued before the confirmation.
    private func replayExecuted(transaction id: Int) {
        state.withLock { state in dispatch(state.gate.replayExecuted(transaction: id), state: &state) }
    }

    /// The tap stopped or the app paused; no events flow until it restarts.
    func tapStopped() {
        state.withLock { state in
            dispatch(state.gate.tapStopped(), state: &state)
        }
    }

    // MARK: - Insertion queue input

    /// Called by the insertion queue right before posting a replacement.
    /// Decided under the lock, so a mouse click, focus change or pause that
    /// the gate saw first wins and nothing is posted.
    func commit(transaction id: Int, secureInput: Bool) -> Bool {
        state.withLock { state in
            let (proceed, effects) = state.gate.commit(transaction: id, secureInput: secureInput)
            dispatch(effects, state: &state)
            return proceed
        }
    }

    // MARK: - Main thread inputs

    func focusMayHaveMoved() {
        state.withLock { state in dispatch(state.gate.focusMayHaveMoved(), state: &state) }
    }

    func probeResult(generation: Int, tokenID: Int?, _ result: FocusResult) {
        state.withLock { state in
            let held = state.held
            let effects = state.gate.probeResult(generation: generation, tokenID: tokenID, result, decode: { Self.text(of: held[$0]) })
            dispatch(effects, state: &state)
        }
    }

    func verifyResult(transaction id: Int, _ result: VerifyResult) {
        state.withLock { state in dispatch(state.gate.verifyResult(transaction: id, result), state: &state) }
    }

    func timeout(transaction id: Int) {
        state.withLock { state in dispatch(state.gate.timeout(transaction: id), state: &state) }
    }

    func focusTracking(active: Bool) {
        state.withLock { state in dispatch(state.gate.focusTracking(active: active), state: &state) }
    }

    func frontmostApp(excluded: Bool) {
        state.withLock { state in state.gate.frontmostApp(excluded: excluded) }
    }

    func pickerVisibility(_ frame: CGRect?) {
        state.withLock { state in
            state.pickerFrame = frame ?? .null
            state.gate.pickerVisibility(frame != nil)
        }
    }

    func pickerClicked() {
        state.withLock { state in dispatch(state.gate.pickerClicked(), state: &state) }
    }

    var capturesText: Bool {
        state.withLock { $0.gate.capturesText }
    }

    // MARK: - Effects

    /// Splits effects by destination, keeping each destination's order. Called
    /// under the lock so posts from different threads cannot interleave.
    private func dispatch(_ effects: [GateEffect], state: inout State) {
        var main: [MainEffect] = []
        for effect in effects {
            switch effect {
            case .requestProbe(let generation, let tokenID):
                main.append(.requestProbe(generation: generation, tokenID: tokenID))
            case .presentPicker(let query, let anchor):
                main.append(.presentPicker(query: query, anchor: anchor))
            case .dismissPicker:
                main.append(.dismissPicker)
            case .moveSelection(let delta):
                main.append(.moveSelection(by: delta))
            case .beginInsertion(let transaction, let source, let typed, let target):
                main.append(.beginInsertion(transaction: transaction, source: source, typed: typed, target: target))
            case .armWatchdog(let transaction):
                main.append(.armWatchdog(transaction: transaction))
            case .transactionEnded(let transaction, let recordUse):
                main.append(.transactionEnded(transaction: transaction, recordUse: recordUse))
            case .post(let transaction, let deleteCount, let text):
                poster.postReplacement(transaction: transaction, deleteCount: deleteCount, text: text, commit: { [weak self] in
                    self?.commit(transaction: transaction, secureInput: IsSecureEventInputEnabled()) ?? false
                }, onFailure: { [weak self] in
                    self?.streamFailed(transaction: transaction)
                })
            case .postFlush(let transaction):
                poster.postFlush(transaction: transaction) { [weak self] in
                    self?.streamFailed(transaction: transaction)
                }
            case .replay(let eventIDs):
                let copies = eventIDs.compactMap { state.held.removeValue(forKey: $0) }
                poster.replay(copies.map(\.event), completion: nil)
            case .confirmReplay(let transaction):
                // Queued behind every replay above: runs once they were posted.
                poster.replay([]) { [weak self] in
                    self?.replayExecuted(transaction: transaction)
                }
            case .drop(let eventIDs):
                for id in eventIDs { state.held.removeValue(forKey: id) }
            case .repost(let keyCode):
                poster.repost(keyCode: keyCode)
            }
        }
        if !main.isEmpty {
            mainHandler(main)
        }
        if let outcome = state.gate.shutdownOutcome, !state.shutdownWaiters.isEmpty {
            let waiters = state.shutdownWaiters.values
            state.shutdownWaiters = [:]
            for waiter in waiters { waiter.resume(returning: outcome) }
        }
    }
}
