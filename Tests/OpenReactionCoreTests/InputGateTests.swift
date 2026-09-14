import CoreGraphics
import OpenReactionCore
import Testing

/// Scripted event sequences against the pure gate. Each review finding
/// (R1–R6) has at least one scenario here.
@Suite("Input gate")
struct InputGateTests {
    typealias Effect = GateEffect

    final class Environment: @unchecked Sendable {
        var excludedApp = false
    }

    /// Drives the gate the way the tap and main thread do, recording the
    /// text decoder calls so tests can prove when characters were read.
    struct Harness {
        var gate: InputGate
        var decoded: [String] = []
        var nextID = 0
        var secureInput = false

        init(gate: InputGate) { self.gate = gate }

        mutating func press(_ keyCode: UInt16, _ text: String = "", modifiers: KeyModifiers = [], repeat isRepeat: Bool = false) -> InputGate.KeyResult {
            nextID += 1
            let event = KeyEvent(keyCode: keyCode, isDown: true, isRepeat: isRepeat, modifiers: modifiers, secureInput: secureInput, id: nextID)
            return gate.key(event) {
                decoded.append(text)
                return text
            }
        }

        mutating func release(_ keyCode: UInt16) -> InputGate.KeyResult {
            nextID += 1
            let event = KeyEvent(keyCode: keyCode, isDown: false, modifiers: [], secureInput: secureInput, id: nextID)
            return gate.key(event) { "" }
        }

        /// Types printable characters (key code 0 with the character as text).
        @discardableResult
        mutating func type(_ string: String) -> [Effect] {
            var effects: [Effect] = []
            for character in string {
                let down = press(0, String(character))
                effects += down.effects
                effects += release(0).effects
            }
            return effects
        }

        mutating func tap(_ keyCode: UInt16) -> [InputGate.KeyResult] {
            [press(keyCode), release(keyCode)]
        }
    }

    let environment = Environment()
    let anchor = CGRect(x: 10, y: 20, width: 0, height: 18)
    let field = FocusTarget(pid: 42, element: 7)
    let otherField = FocusTarget(pid: 42, element: 8)
    var editable: FocusResult { .editable(anchor: anchor, target: field) }

    /// A gate whose focus was probed once and found editable.
    private func makeHarness(open: Bool = true) -> Harness {
        let environment = environment
        var harness = Harness(gate: InputGate(isFrontmostAppExcluded: { environment.excludedApp }))
        if open {
            _ = harness.gate.focusMayHaveMoved()
            _ = harness.gate.probeResult(generation: harness.gate.currentFocusGeneration, tokenID: nil, editable)
        }
        return harness
    }

    private func probes(_ effects: [Effect]) -> [(generation: Int, tokenID: Int?)] {
        effects.compactMap { if case .requestProbe(let g, let t) = $0 { return (g, t) } else { return nil } }
    }

    private func insertions(_ effects: [Effect]) -> [Int] {
        effects.compactMap { if case .beginInsertion(let id, _, _, _) = $0 { return id } else { return nil } }
    }

    private func posts(_ effects: [Effect]) -> [Effect] {
        effects.filter { if case .post = $0 { return true } else { return false } }
    }

    /// Types `:tada`, answers the token probe, and returns the harness.
    private func harnessWithToken() -> Harness {
        var harness = makeHarness()
        let effects = harness.type(":tada")
        let probe = probes(effects).last!
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, editable)
        return harness
    }

    /// Runs `:tada:` to the point where the app verifies. Returns the transaction id.
    private func startTransaction(_ harness: inout Harness) -> Int {
        let effects = harness.type(":")
        let ids = insertions(effects)
        #expect(ids.count == 1)
        #expect(effects.contains(.armWatchdog(transaction: ids[0])))
        return ids[0]
    }

    // MARK: R1 — capture closes before any focus-moving event passes

    @Test func nothingIsDecodedWhileClosed() {
        var harness = makeHarness(open: false)
        harness.type(":tada:")
        #expect(harness.decoded.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func probeForTheCurrentGenerationOpensCapture() {
        var harness = makeHarness(open: false)
        let effects = harness.gate.focusMayHaveMoved()
        let generation = probes(effects).first!.generation
        _ = harness.gate.probeResult(generation: generation, tokenID: nil, editable)
        #expect(harness.gate.capturesText)
        harness.type(":ta")
        #expect(harness.decoded == [":", "t", "a"])
    }

    @Test func staleProbeDoesNotOpenCapture() {
        var harness = makeHarness(open: false)
        let first = probes(harness.gate.focusMayHaveMoved()).first!.generation
        _ = harness.gate.focusMayHaveMoved()
        #expect(harness.gate.probeResult(generation: first, tokenID: nil, editable).isEmpty)
        #expect(!harness.gate.capturesText)
    }

    @Test(arguments: [KeyCode.tab, KeyCode.return, KeyCode.keypadEnter])
    func tabOrReturnPassingToTheHostClosesCaptureBeforeMoreTyping(keyCode: UInt16) {
        var harness = makeHarness()
        harness.type("abc")
        let result = harness.press(keyCode)
        #expect(result.decision == .pass)
        #expect(!harness.gate.capturesText)
        #expect(probes(result.effects).count == 1)
        _ = harness.release(keyCode)
        // Password typed before the probe answers is never decoded.
        harness.decoded.removeAll()
        harness.type("hunter2")
        #expect(harness.decoded.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func mouseDownClosesCaptureSynchronously() {
        var harness = makeHarness()
        let effects = harness.gate.mouseDown(onPicker: false)
        #expect(!harness.gate.capturesText)
        #expect(probes(effects).count == 1)
        harness.type(":x")
        #expect(harness.decoded.isEmpty)
    }

    @Test func clickOnThePickerChangesNothing() {
        var harness = harnessWithToken()
        #expect(harness.gate.mouseDown(onPicker: true).isEmpty)
        #expect(harness.gate.capturesText)
    }

    @Test(arguments: [KeyModifiers.command, .control, .option])
    func modifierChordsCloseCaptureAndAreNotDecoded(modifier: KeyModifiers) {
        var harness = makeHarness()
        let result = harness.press(0, "a", modifiers: modifier)
        #expect(result.decision == .pass)
        #expect(harness.decoded.isEmpty)
        #expect(!harness.gate.capturesText)
    }

    @Test func secureInputIsNeverDecodedAndClearsTyping() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.secureInput = true
        harness.decoded.removeAll()
        let result = harness.press(0, "d")
        #expect(result.decision == .pass)
        #expect(harness.decoded.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func activationClosesCaptureUntilReprobed() {
        var harness = makeHarness()
        _ = harness.gate.focusMayHaveMoved()
        #expect(!harness.gate.capturesText)
        harness.type(":ta")
        #expect(harness.decoded.isEmpty)
    }

    @Test func probeAnsweringSecureClosesCapture() {
        var harness = makeHarness()
        harness.type(":ta")
        let probe = probes(harness.type("d")).first ?? probes(harness.gate.focusMayHaveMoved()).first!
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, .secure)
        #expect(!harness.gate.capturesText)
        #expect(harness.gate.token == nil)
    }

    // MARK: Insertion requires a completed editable probe (prior P1-1)

    @Test func closingColonBeforeTheTokenProbeInsertsNothing() {
        var harness = makeHarness()
        let effects = harness.type(":tada:")
        #expect(insertions(effects).isEmpty)
        #expect(probes(effects).count == 1)
    }

    @Test func closingColonAfterEditableProbeBeginsATransaction() {
        var harness = harnessWithToken()
        let effects = harness.type(":")
        #expect(effects.contains(.beginInsertion(transaction: 1, source: .shortcode("tada"), typed: ":tada:", target: field)))
        #expect(harness.gate.isHolding)
    }

    @Test func excludedAppNeverProbesOrInserts() {
        environment.excludedApp = true
        var harness = makeHarness()
        let effects = harness.type(":tada:")
        #expect(probes(effects).isEmpty)
        #expect(insertions(effects).isEmpty)
    }

    // MARK: R2 — verification may post only for a live, authorized transaction

    @Test func verifiedTransactionPostsThenDrains() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let effects = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        #expect(effects == [.post(transaction: id, deleteCount: 6, text: "🎉"), .armWatchdog(transaction: id)])
        let done = harness.gate.flushAck(transaction: id)
        #expect(done == [.disarmWatchdog, .recordUse(transaction: id)])
        #expect(!harness.gate.isHolding)
        // History now ends with the emoji (a boundary), so a new colon triggers.
        #expect(probes(harness.type(":s")).count == 1)
    }

    @Test func lateVerifyAfterTimeoutPostsNothing() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let timeout = harness.gate.timeout(transaction: id)
        #expect(posts(timeout).isEmpty)
        #expect(timeout.contains(.postFlush(transaction: id)))
        #expect(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")).isEmpty)
        _ = harness.gate.flushAck(transaction: id)
        #expect(!harness.gate.isHolding)
        #expect(harness.gate.token == nil)
    }

    @Test func mouseDownDuringVerificationCancelsBeforePosting() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let effects = harness.gate.mouseDown(onPicker: false)
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")).isEmpty)
        #expect(harness.gate.flushAck(transaction: id).contains(.disarmWatchdog))
        #expect(!harness.gate.isHolding)
    }

    @Test func focusChangeDuringVerificationRevokesPosting() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.focusMayHaveMoved()
        #expect(posts(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))).isEmpty)
    }

    @Test func pauseOrTapStopRevokesPostingAndReplaysHeld() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.press(0, "x")
        let effects = harness.gate.paused()
        #expect(effects.contains(.replay(eventIDs: [harness.nextID])))
        #expect(!harness.gate.isHolding)
        #expect(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")).isEmpty)
    }

    @Test func refusedVerificationPostsNothingAndForgets() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let effects = harness.gate.verifyResult(transaction: id, .refused)
        #expect(posts(effects).isEmpty)
        #expect(effects.contains(.postFlush(transaction: id)))
        let done = harness.gate.flushAck(transaction: id)
        #expect(!done.contains(.recordUse(transaction: id)))
        #expect(harness.gate.token == nil)
    }

    @Test func accessibilityReplacementSkipsPostingAndRecordsUse() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let effects = harness.gate.verifyResult(transaction: id, .replaced(text: "🎉"))
        #expect(posts(effects).isEmpty)
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(harness.gate.flushAck(transaction: id).contains(.recordUse(transaction: id)))
    }

    @Test func staleTransactionAnswersAreIgnored() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.gate.flushAck(transaction: id)
        #expect(harness.gate.flushAck(transaction: id).isEmpty)
        #expect(harness.gate.timeout(transaction: id).isEmpty)
        #expect(harness.gate.verifyResult(transaction: id + 5, .keystrokes(text: "x")).isEmpty)
    }

    // MARK: R3 — the watchdog outlives posting; drains keep order

    @Test func watchdogStaysArmedUntilTheDrainCompletes() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let posted = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        #expect(posted.contains(.armWatchdog(transaction: id)))
        _ = harness.press(0, "x")
        let drain = harness.gate.flushAck(transaction: id)
        #expect(drain.contains(.armWatchdog(transaction: id)))
        #expect(!drain.contains(.disarmWatchdog))
        #expect(harness.gate.flushAck(transaction: id).contains(.disarmWatchdog))
    }

    @Test func lostFlushRetriesOnceThenAbandonsWithReplay() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.press(0, "x")
        let retry = harness.gate.timeout(transaction: id)
        #expect(retry == [.postFlush(transaction: id), .armWatchdog(transaction: id)])
        #expect(harness.gate.isHolding)
        let abandon = harness.gate.timeout(transaction: id)
        #expect(abandon.contains(.replay(eventIDs: [harness.nextID])))
        #expect(abandon.contains(.disarmWatchdog))
        #expect(!harness.gate.isHolding)
    }

    @Test func keysArrivingDuringTheDrainAreHeldUntilTheNextAck() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        let first = harness.press(0, "a")
        #expect(first.decision == .hold)
        let drain = harness.gate.flushAck(transaction: id)
        #expect(drain.contains(.replay(eventIDs: [harness.nextID])))
        // Still draining: live keys keep being held, so nothing overtakes the replay.
        let second = harness.press(0, "b")
        #expect(second.decision == .hold)
        let drain2 = harness.gate.flushAck(transaction: id)
        #expect(drain2.contains(.replay(eventIDs: [harness.nextID])))
        #expect(harness.gate.flushAck(transaction: id).contains(.disarmWatchdog))
    }

    @Test func tapInterruptionAbandonsAndClosesCapture() {
        var harness = harnessWithToken()
        _ = startTransaction(&harness)
        _ = harness.press(0, "x")
        let effects = harness.gate.tapInterrupted()
        #expect(effects.contains(.replay(eventIDs: [harness.nextID])))
        #expect(!harness.gate.isHolding)
        #expect(!harness.gate.capturesText)
    }

    // MARK: R5 — ownership is independent of holding

    @Test func returnReleasedDuringVerificationIsSwallowedAndUnowned() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        let down = harness.press(KeyCode.return)
        #expect(down.decision == .swallow)
        #expect(insertions(down.effects).count == 1)
        harness.gate.pickerVisibility(false)
        // Still verifying: the release is ours, not held, not replayed.
        let up = harness.release(KeyCode.return)
        #expect(up.decision == .swallow)
        _ = harness.gate.verifyResult(transaction: 1, .keystrokes(text: "🎉"))
        _ = harness.gate.flushAck(transaction: 1)
        // The next Return press reaches the host normally.
        let next = harness.press(KeyCode.return)
        #expect(next.decision == .pass)
        #expect(harness.release(KeyCode.return).decision == .pass)
    }

    @Test func repeatsOfASwallowedKeyNeverReachTheHost() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        #expect(harness.press(KeyCode.downArrow).decision == .swallow)
        let repeated = harness.press(KeyCode.downArrow, repeat: true)
        #expect(repeated.decision == .swallow)
        #expect(repeated.effects == [.moveSelection(by: 1)])
        harness.gate.pickerVisibility(false)
        #expect(harness.press(KeyCode.downArrow, repeat: true).decision == .swallow)
        #expect(harness.release(KeyCode.downArrow).decision == .swallow)
        #expect(harness.press(KeyCode.downArrow).decision == .pass)
    }

    @Test func returnRepeatsDuringAHoldAreDroppedNotReplayed() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        _ = harness.press(KeyCode.return)
        harness.gate.pickerVisibility(false)
        #expect(harness.press(KeyCode.return, repeat: true).decision == .swallow)
        #expect(harness.release(KeyCode.return).decision == .swallow)
        _ = harness.gate.verifyResult(transaction: 1, .keystrokes(text: "🎉"))
        let drain = harness.gate.flushAck(transaction: 1)
        #expect(!drain.contains { if case .replay = $0 { return true } else { return false } })
    }

    @Test func interruptionClearsOwnership() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        _ = harness.press(KeyCode.escape)
        _ = harness.gate.tapInterrupted()
        harness.gate.pickerVisibility(false)
        #expect(harness.release(KeyCode.escape).decision == .pass)
    }

    // MARK: R6 — drained keys go through the trigger logic exactly once

    @Test func shortcodeTypedDuringAHoldIsRecognizedWhenDrained() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        harness.type(" :sm")
        let drain = harness.gate.flushAck(transaction: id)
        // The held keys (4 presses, 4 releases) are replayed to the host and a
        // new token probe is requested.
        #expect(drain.contains { if case .replay(let ids) = $0 { return ids.count == 8 } else { return false } })
        #expect(probes(drain).count == 1)
        #expect(harness.gate.token?.query == "sm")
    }

    @Test func drainedTextKeepsWordBoundariesCorrect() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        harness.type("http")
        _ = harness.gate.flushAck(transaction: id)
        _ = harness.gate.flushAck(transaction: id)
        // Host text is 🎉http; a colon here follows a letter and must not trigger.
        let effects = harness.type(":ta")
        #expect(probes(effects).isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func drainedClosingColonStartsTheNextTransactionAndHoldsTheRest() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        harness.type(" :tada")
        // The token probe for the drained :tada arrives only after the drain
        // (it is requested by the drain), so this colon cannot complete yet.
        let drain = harness.gate.flushAck(transaction: id)
        let probe = probes(drain).first!
        _ = harness.gate.flushAck(transaction: id)
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, editable)
        let effects = harness.type(":")
        #expect(insertions(effects) == [id + 1])
    }

    @Test func drainedKeysAreNotDecodedIfCaptureWasClosedWhenTheyArrived() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.press(KeyCode.tab)
        harness.decoded.removeAll()
        harness.type("secret")
        // Tab was held, not yet processed, so capture was still open: the text
        // was decoded at arrival. Once drained, the Tab closes the gate and
        // everything after it is forgotten and re-probed.
        let drain = harness.gate.flushAck(transaction: id)
        #expect(probes(drain).count == 1)
        #expect(harness.gate.token == nil)
        #expect(!harness.gate.capturesText)
    }

    // MARK: Picker commands (prior P1-3)

    @Test func pickerCommandsPassWhileHiddenAndResetTyping() {
        var harness = harnessWithToken()
        #expect(harness.press(KeyCode.downArrow).decision == .pass)
        #expect(harness.gate.token == nil)
    }

    @Test func pickerCommandsAreSwallowedWhileVisible() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        let down = harness.press(KeyCode.downArrow)
        #expect(down.decision == .swallow)
        #expect(down.effects == [.moveSelection(by: 1)])
        let escape = harness.press(KeyCode.escape)
        #expect(escape.decision == .swallow)
        #expect(harness.gate.token?.isDismissed == true)
    }

    @Test func confirmWithoutAProbeAnswerIsRepostedNotInserted() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.gate.pickerVisibility(true)
        let result = harness.press(KeyCode.return)
        #expect(result.decision == .swallow)
        #expect(result.effects.contains(.repost(keyCode: KeyCode.return)))
        #expect(insertions(result.effects).isEmpty)
    }

    @Test func clickingARowInsertsTheSelection() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        let effects = harness.gate.pickerClicked()
        #expect(effects.contains(.beginInsertion(transaction: 1, source: .selection, typed: ":tada", target: field)))
    }

    @Test func lateTokenProbeForAnOldTokenIsIgnored() {
        var harness = makeHarness()
        let first = probes(harness.type(":ta ")).first!
        let second = probes(harness.type(":sm")).first!
        #expect(harness.gate.probeResult(generation: first.generation, tokenID: first.tokenID, editable) == [.dismissPicker])
        #expect(harness.gate.probeResult(generation: second.generation, tokenID: second.tokenID, editable) == [.presentPicker(query: "sm", anchor: anchor)])
    }

    @Test func shiftTabMovesFocusAndClosesCapture() {
        var harness = makeHarness()
        #expect(harness.press(KeyCode.tab, modifiers: .shift).decision == .pass)
        #expect(!harness.gate.capturesText)
    }

    @Test func releaseOfAKeyPressedBeforeTheHoldPassesThrough() {
        var harness = harnessWithToken()
        _ = harness.press(0, ":")
        #expect(harness.gate.isHolding)
        #expect(harness.release(0).decision == .pass)
        // A press during the hold is held together with its release, in order.
        #expect(harness.press(0, "x").decision == .hold)
        #expect(harness.release(0).decision == .hold)
    }
}
