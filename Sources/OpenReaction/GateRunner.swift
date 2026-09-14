import AppKit
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
        case disarmWatchdog
        case recordUse(transaction: Int)
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
    }

    private let state: OSAllocatedUnfairLock<State>
    private let mainHandler: @Sendable ([MainEffect]) -> Void

    init(gate: InputGate, mainHandler: @escaping @Sendable ([MainEffect]) -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(gate: gate))
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

    func mouseDown(at location: CGPoint) {
        state.withLock { state in
            let onPicker = state.gate.isPickerVisible && state.pickerFrame.contains(location)
            dispatch(state.gate.mouseDown(onPicker: onPicker), state: &state)
        }
    }

    func flushAck(transaction id: Int) {
        state.withLock { state in
            dispatch(state.gate.flushAck(transaction: id), state: &state)
        }
    }

    func tapInterrupted() {
        state.withLock { state in
            dispatch(state.gate.tapInterrupted(), state: &state)
        }
    }

    // MARK: - Main thread inputs

    func focusMayHaveMoved() {
        state.withLock { state in dispatch(state.gate.focusMayHaveMoved(), state: &state) }
    }

    func probeResult(generation: Int, tokenID: Int?, _ result: FocusResult) {
        state.withLock { state in dispatch(state.gate.probeResult(generation: generation, tokenID: tokenID, result), state: &state) }
    }

    func verifyResult(transaction id: Int, _ result: VerifyResult) {
        state.withLock { state in dispatch(state.gate.verifyResult(transaction: id, result), state: &state) }
    }

    func timeout(transaction id: Int) {
        state.withLock { state in dispatch(state.gate.timeout(transaction: id), state: &state) }
    }

    func paused() {
        state.withLock { state in dispatch(state.gate.paused(), state: &state) }
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
            case .disarmWatchdog:
                main.append(.disarmWatchdog)
            case .recordUse(let transaction):
                main.append(.recordUse(transaction: transaction))
            case .post(let transaction, let deleteCount, let text):
                TextInserter.postReplacement(transaction: transaction, deleteCount: deleteCount, text: text)
            case .postFlush(let transaction):
                TextInserter.postFlush(transaction: transaction)
            case .replay(let eventIDs):
                let copies = eventIDs.compactMap { state.held.removeValue(forKey: $0) }
                TextInserter.replay(copies.map(\.event))
            case .drop(let eventIDs):
                for id in eventIDs { state.held.removeValue(forKey: id) }
            case .repost(let keyCode):
                TextInserter.repost(keyCode: keyCode)
            }
        }
        if !main.isEmpty {
            mainHandler(main)
        }
    }
}
