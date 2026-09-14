import CoreGraphics
import OpenReactionCore
import Testing

/// Scripted event sequences against the pure gate. Every review finding has
/// at least one scenario here; the harness types with real US-layout key
/// codes and modifier flags, the way the tap would.
@Suite("Input gate")
struct InputGateTests {
    typealias Effect = GateEffect

    /// US keyboard: key code, whether Shift is held, and the character produced.
    static let usLayout: [Character: (code: UInt16, shift: Bool)] = {
        var map: [Character: (UInt16, Bool)] = [:]
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
            ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
            (" ", 49),
        ]
        for (character, code) in letters {
            map[character] = (code, false)
            if character.isLetter { map[Character(character.uppercased())] = (code, true) }
        }
        map[";"] = (41, false); map[":"] = (41, true)
        map["="] = (24, false); map["+"] = (24, true)
        map["-"] = (27, false); map["_"] = (27, true)
        map["/"] = (44, false); map["?"] = (44, true)
        map["."] = (47, false); map[">"] = (47, true)
        map["'"] = (39, false); map["\""] = (39, true)
        map["9"] = (25, false); map["("] = (25, true)
        return map
    }()

    /// Drives the gate the way the tap and main thread do, recording the
    /// decoder calls so tests can prove when characters were read.
    struct Harness {
        var gate = InputGate()
        var decoded: [String] = []
        var nextID = 0
        var secureInput = false

        mutating func press(_ keyCode: UInt16, _ text: String = "", modifiers: KeyModifiers = [], repeat isRepeat: Bool = false) -> InputGate.KeyResult {
            nextID += 1
            let event = KeyEvent(keyCode: keyCode, isDown: true, isRepeat: isRepeat, modifiers: modifiers, secureInput: secureInput, id: nextID)
            return gate.key(event) {
                decoded.append(text)
                return text
            }
        }

        mutating func release(_ keyCode: UInt16, modifiers: KeyModifiers = []) -> InputGate.KeyResult {
            nextID += 1
            let event = KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers, secureInput: secureInput, id: nextID)
            return gate.key(event) { "" }
        }

        /// Types characters with US-layout key codes and Shift where needed.
        @discardableResult
        mutating func type(_ string: String, capsLock: Bool = false) -> [Effect] {
            var effects: [Effect] = []
            for character in string {
                guard let key = Self.key(for: character) else { fatalError("no key for \(character)") }
                let modifiers: KeyModifiers = key.shift ? .shift : []
                let text = capsLock && character.isLetter ? String(character).uppercased() : String(character)
                effects += press(key.code, text, modifiers: modifiers).effects
                effects += release(key.code, modifiers: modifiers).effects
            }
            return effects
        }

        static func key(for character: Character) -> (code: UInt16, shift: Bool)? {
            InputGateTests.usLayout[character]
        }
    }

    let anchor = CGRect(x: 10, y: 20, width: 0, height: 18)
    let field = FocusTarget(pid: 42, element: 7)
    var editable: FocusResult { .editable(anchor: anchor, target: field) }

    /// A gate with focus tracking active and the focused field probed editable.
    private func makeHarness(open: Bool = true) -> Harness {
        var harness = Harness()
        if open {
            _ = harness.gate.focusTracking(active: true)
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

    private func replays(_ effects: [Effect]) -> [[Int]] {
        effects.compactMap { if case .replay(let ids) = $0 { return ids } else { return nil } }
    }

    private func ended(_ effects: [Effect], _ id: Int, recorded: Bool) -> Bool {
        effects.contains(.transactionEnded(transaction: id, recordUse: recorded))
    }

    /// Types `:tada`, answers the token probe, and returns the harness.
    private func harnessWithToken(_ shortcode: String = "tada") -> Harness {
        var harness = makeHarness()
        let effects = harness.type(":" + shortcode)
        let probe = probes(effects).last!
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, editable)
        return harness
    }

    /// Types the closing colon; returns the transaction id.
    private func startTransaction(_ harness: inout Harness) -> Int {
        let effects = harness.type(":")
        let ids = insertions(effects)
        #expect(ids.count == 1)
        #expect(effects.contains(.armWatchdog(transaction: ids[0])))
        return ids[0]
    }

    /// Verifies and commits; returns the transaction id in `posting`.
    private func postTransaction(_ harness: inout Harness) -> Int {
        let id = startTransaction(&harness)
        let effects = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        #expect(effects == [.post(transaction: id, deleteCount: 6, text: "🎉"), .armWatchdog(transaction: id)])
        let commit = harness.gate.commit(transaction: id, secureInput: false)
        #expect(commit.proceed)
        return id
    }

    // MARK: G4 — golden typing with real key codes and Shift

    @Test func colonIsShiftSemicolonAndTriggers() {
        var harness = makeHarness()
        let effects = harness.type(":tada")
        #expect(harness.decoded == [":", "t", "a", "d", "a"])
        #expect(harness.gate.token?.query == "tada")
        #expect(probes(effects).count == 1)
    }

    @Test func fullShortcodeWithShiftedColonsCompletes() {
        var harness = harnessWithToken()
        let effects = harness.type(":")
        #expect(effects.contains(.beginInsertion(transaction: 1, source: .shortcode("tada"), typed: ":tada:", target: field)))
    }

    @Test func plusOneUsesShiftEquals() {
        var harness = makeHarness()
        harness.type(":+1")
        #expect(harness.gate.token?.query == "+1")
        #expect(harness.gate.token?.typed == ":+1")
    }

    @Test func underscoreUsesShiftMinus() {
        var harness = makeHarness()
        harness.type(":thumbs_up")
        #expect(harness.gate.token?.query == "thumbs_up")
    }

    @Test func capsLockTypesUppercaseThatStillMatches() {
        var harness = makeHarness()
        harness.type(":tada", capsLock: true)
        #expect(harness.gate.token?.query == "tada")
        #expect(harness.gate.token?.typed == ":TADA")
    }

    @Test func autorepeatOfALetterTypesItAgain() {
        var harness = makeHarness()
        harness.type(":ta")
        let key = Harness.key(for: "a")!
        _ = harness.press(key.code, "a", repeat: true)
        #expect(harness.gate.token?.query == "taa")
    }

    @Test func shiftAloneDoesNotBlockDecodingButChordsDo() {
        var harness = makeHarness()
        _ = harness.press(41, ":", modifiers: .shift)
        #expect(harness.decoded == [":"])
        harness.decoded.removeAll()
        _ = harness.press(41, ":", modifiers: [.shift, .command])
        #expect(harness.decoded.isEmpty)
    }

    @Test func shiftedNavigationKeysStillNavigate() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        #expect(harness.press(KeyCode.downArrow, modifiers: .shift).decision == .pass)
        #expect(harness.gate.token == nil)
        var second = makeHarness()
        #expect(second.press(KeyCode.tab, modifiers: .shift).decision == .pass)
        #expect(!second.gate.capturesText)
    }

    // MARK: G1 — capture needs focused-element tracking

    @Test func editableProbeDoesNotOpenCaptureWithoutTracking() {
        var harness = Harness()
        _ = harness.gate.focusMayHaveMoved()
        _ = harness.gate.probeResult(generation: harness.gate.currentFocusGeneration, tokenID: nil, editable)
        #expect(!harness.gate.capturesText)
        harness.type(":ta")
        #expect(harness.decoded.isEmpty)
    }

    @Test func trackingBecomingActiveRequestsAProbeAndThenOpens() {
        var harness = Harness()
        let effects = harness.gate.focusTracking(active: true)
        let probe = probes(effects).first!
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: nil, editable)
        #expect(harness.gate.capturesText)
    }

    @Test func losingTrackingClosesCaptureAndForgets() {
        var harness = makeHarness()
        harness.type(":ta")
        let effects = harness.gate.focusTracking(active: false)
        #expect(effects.contains(.dismissPicker))
        #expect(!harness.gate.capturesText)
        #expect(harness.gate.token == nil)
        // No probe is requested while untracked; an answer could not open anyway.
        #expect(probes(effects).isEmpty)
    }

    @Test func trackingLostBeforeCommitCancels() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.gate.focusTracking(active: false)
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    // MARK: R1 — capture closes before any focus-moving event passes

    @Test func nothingIsDecodedWhileClosed() {
        var harness = makeHarness(open: false)
        harness.type(":tada:")
        #expect(harness.decoded.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func staleProbeDoesNotOpenCapture() {
        var harness = makeHarness(open: false)
        _ = harness.gate.focusTracking(active: true)
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
        let result = harness.press(2, "d")
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
        let probe = probes(harness.type(":ta")).first!
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, .secure)
        #expect(!harness.gate.capturesText)
        #expect(harness.gate.token == nil)
    }

    // MARK: Insertion requires a completed editable probe

    @Test func closingColonBeforeTheTokenProbeInsertsNothing() {
        var harness = makeHarness()
        let effects = harness.type(":tada:")
        #expect(insertions(effects).isEmpty)
        #expect(probes(effects).count == 1)
    }

    @Test func excludedAppNeverProbesOrInserts() {
        var harness = makeHarness()
        harness.gate.frontmostApp(excluded: true)
        let effects = harness.type(":tada:")
        #expect(probes(effects).isEmpty)
        #expect(insertions(effects).isEmpty)
    }

    // MARK: G3 — nothing posts unless commit succeeds at execution time

    @Test func committedTransactionPostsThenDrainsAndRecords() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        let done = harness.gate.flushAck(transaction: id)
        #expect(ended(done, id, recorded: true))
        #expect(!harness.gate.isHolding)
        // History ends with the emoji (a boundary), so a new colon triggers.
        #expect(probes(harness.type(":s")).count == 1)
    }

    @Test func mouseDownBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        let effects = harness.gate.mouseDown(onPicker: false)
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: false))
    }

    @Test func focusChangeBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.gate.focusMayHaveMoved()
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func pauseBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.gate.tapStopped()
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func secureInputAtCommitTimeRefusesAndCancels() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        let commit = harness.gate.commit(transaction: id, secureInput: true)
        #expect(!commit.proceed)
        #expect(commit.effects.contains(.postFlush(transaction: id)))
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: false))
    }

    @Test func timeoutBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        _ = harness.gate.timeout(transaction: id)
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func secureKeyBeforeCommitCancels() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        harness.secureInput = true
        _ = harness.press(7, "x")
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func commitIsOnlyValidOnceAndOnlyWhenAuthorized() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
        _ = harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉"))
        #expect(harness.gate.commit(transaction: id, secureInput: false).proceed)
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
        #expect(!harness.gate.commit(transaction: id + 1, secureInput: false).proceed)
    }

    @Test func lateVerifyAfterTimeoutPostsNothing() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let timeout = harness.gate.timeout(transaction: id)
        #expect(posts(timeout).isEmpty)
        #expect(timeout.contains(.postFlush(transaction: id)))
        #expect(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")).isEmpty)
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: false))
        #expect(!harness.gate.isHolding)
    }

    @Test func refusedVerificationPostsNothingAndForgets() {
        var harness = harnessWithToken()
        let id = startTransaction(&harness)
        let effects = harness.gate.verifyResult(transaction: id, .refused)
        #expect(posts(effects).isEmpty)
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: false))
        #expect(harness.gate.token == nil)
    }

    @Test func staleTransactionAnswersAreIgnored() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.gate.flushAck(transaction: id)
        #expect(harness.gate.flushAck(transaction: id).isEmpty)
        #expect(harness.gate.timeout(transaction: id).isEmpty)
        #expect(harness.gate.verifyResult(transaction: id + 5, .keystrokes(text: "x")).isEmpty)
    }

    // MARK: R3 / G6 — watchdog, drains and recovery keep order

    @Test func watchdogStaysArmedUntilTheDrainCompletes() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.press(7, "x")
        let drain = harness.gate.flushAck(transaction: id)
        #expect(drain.contains(.armWatchdog(transaction: id)))
        #expect(!drain.contains { if case .transactionEnded = $0 { return true } else { return false } })
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: true))
    }

    @Test func keysArrivingDuringTheDrainAreHeldUntilTheNextAck() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        #expect(harness.press(0, "a").decision == .hold)
        let drain = harness.gate.flushAck(transaction: id)
        #expect(replays(drain) == [[harness.nextID]])
        #expect(harness.press(11, "b").decision == .hold)
        let drain2 = harness.gate.flushAck(transaction: id)
        #expect(replays(drain2) == [[harness.nextID]])
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: true))
    }

    @Test func lostFlushRetriesThenRecoversThenGivesUpInOrder() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.press(7, "x")
        let xDown = harness.nextID
        // 1st timeout: re-flush, still holding.
        #expect(harness.gate.timeout(transaction: id) == [.postFlush(transaction: id), .armWatchdog(transaction: id)])
        #expect(harness.gate.isHolding)
        // 2nd timeout: recovery replays what is held but keeps holding new input.
        let recover = harness.gate.timeout(transaction: id)
        #expect(replays(recover) == [[xDown]])
        #expect(recover.contains(.postFlush(transaction: id)))
        #expect(harness.gate.isHolding)
        #expect(harness.press(16, "y").decision == .hold)
        // Give up: everything owed goes out in order, and x (replayed down,
        // release not seen) is balanced with a release.
        var effects: [Effect] = []
        while harness.gate.isHolding { effects = harness.gate.timeout(transaction: id) }
        #expect(replays(effects).contains([harness.nextID]))
        // Both x (replayed earlier) and y (replayed now) had no release seen.
        #expect(effects.contains(.release(keyCodes: [7, 16])))
        #expect(ended(effects, id, recorded: false))
    }

    @Test func releaseArrivingDuringRecoveryBalancesTheReplayedPress() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.press(7, "x")
        _ = harness.gate.timeout(transaction: id)
        _ = harness.gate.timeout(transaction: id) // recovery replayed x-down
        // The physical x-up passes now (its down is already replayed) and is
        // remembered, so giving up does not release x a second time.
        #expect(harness.release(7).decision == .pass)
        var effects: [Effect] = []
        while harness.gate.isHolding { effects = harness.gate.timeout(transaction: id) }
        #expect(!effects.contains { if case .release = $0 { return true } else { return false } })
    }

    @Test func recoveryAcknowledgedResumesNormalDraining() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.gate.timeout(transaction: id)
        _ = harness.gate.timeout(transaction: id)
        #expect(ended(harness.gate.flushAck(transaction: id), id, recorded: true))
    }

    @Test func tapInterruptionRecoversInsteadOfReopening() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.press(7, "x")
        let effects = harness.gate.tapInterrupted()
        #expect(replays(effects) == [[harness.nextID]])
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(harness.gate.isHolding)
        #expect(!harness.gate.capturesText)
        // Its release is held-ordering-safe: the down was replayed, the up passes.
        #expect(harness.release(7).decision == .pass)
    }

    @Test func tapStopDeliversEverythingOwedAndResets() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.press(7, "x")
        let effects = harness.gate.tapStopped()
        #expect(replays(effects) == [[harness.nextID]])
        #expect(effects.contains(.release(keyCodes: [7])))
        #expect(ended(effects, id, recorded: false))
        #expect(!harness.gate.isHolding)
        #expect(!harness.gate.capturesText)
    }

    @Test func heldPressAndReleasePairStayTogether() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        #expect(harness.press(7, "x").decision == .hold)
        #expect(harness.release(7).decision == .hold)
        let drain = harness.gate.flushAck(transaction: id)
        #expect(replays(drain) == [[harness.nextID - 1, harness.nextID]])
    }

    @Test func releaseOfAKeyPressedBeforeTheHoldPassesThrough() {
        var harness = harnessWithToken()
        _ = harness.press(41, ":", modifiers: .shift)
        #expect(harness.gate.isHolding)
        #expect(harness.release(41, modifiers: .shift).decision == .pass)
    }

    // MARK: R5 — ownership is independent of holding

    @Test func returnReleasedDuringVerificationIsSwallowedAndUnowned() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        let down = harness.press(KeyCode.return)
        #expect(down.decision == .swallow)
        #expect(insertions(down.effects).count == 1)
        harness.gate.pickerVisibility(false)
        #expect(harness.release(KeyCode.return).decision == .swallow)
        _ = harness.gate.verifyResult(transaction: 1, .keystrokes(text: "🎉"))
        _ = harness.gate.commit(transaction: 1, secureInput: false)
        _ = harness.gate.flushAck(transaction: 1)
        #expect(harness.press(KeyCode.return).decision == .pass)
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
        _ = harness.gate.commit(transaction: 1, secureInput: false)
        #expect(replays(harness.gate.flushAck(transaction: 1)).isEmpty)
    }

    @Test func stopClearsOwnershipWithoutSynthesizingReleases() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        _ = harness.press(KeyCode.escape)
        let effects = harness.gate.tapStopped()
        #expect(!effects.contains { if case .release = $0 { return true } else { return false } })
        harness.gate.pickerVisibility(false)
        #expect(harness.release(KeyCode.escape).decision == .pass)
    }

    // MARK: R6 / G7 — drained keys go through the trigger logic exactly once

    @Test func shortcodeTypedDuringAHoldIsRecognizedWhenDrained() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        harness.type(" :sm")
        let drain = harness.gate.flushAck(transaction: id)
        #expect(replays(drain).first?.count == 8)
        #expect(probes(drain).count == 1)
        #expect(harness.gate.token?.query == "sm")
    }

    @Test func drainedTextKeepsWordBoundariesCorrect() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        harness.type("http")
        _ = harness.gate.flushAck(transaction: id)
        _ = harness.gate.flushAck(transaction: id)
        // Host text is 🎉http; a colon here follows a letter and must not trigger.
        #expect(probes(harness.type(":ta")).isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func pickerForADrainedTokenAppearsOnceTheTransactionEnds() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        harness.type(" :sm")
        let drain = harness.gate.flushAck(transaction: id)
        let probe = probes(drain).first!
        // The probe answers before the final empty flush: nothing to show yet.
        #expect(harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, editable) == [.dismissPicker])
        let done = harness.gate.flushAck(transaction: id)
        #expect(done.contains(.presentPicker(query: "sm", anchor: anchor)))
    }

    @Test func closingColonDrainedDuringATransactionStartsTheNextOneInOrder() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        harness.type(" :tada")
        let drain = harness.gate.flushAck(transaction: id)
        let probe = probes(drain).first!
        _ = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, editable)
        // The closing colon and an extra key arrive while still draining.
        harness.type(":x")
        let xDown = harness.nextID - 1
        let drain2 = harness.gate.flushAck(transaction: id)
        // The colon press is replayed; everything after it waits for the next transaction.
        #expect(replays(drain2).first?.count == 1)
        #expect(!replays(drain2).joined().contains(xDown))
        let done = harness.gate.flushAck(transaction: id)
        #expect(ended(done, id, recorded: true))
        #expect(insertions(done) == [id + 1])
        // x is delivered after the second replacement.
        _ = harness.gate.verifyResult(transaction: id + 1, .keystrokes(text: "🎉"))
        _ = harness.gate.commit(transaction: id + 1, secureInput: false)
        #expect(replays(harness.gate.flushAck(transaction: id + 1)).joined().contains(xDown))
    }

    @Test func drainedKeysAreNotDecodedIfCaptureWasClosedWhenTheyArrived() {
        var harness = harnessWithToken()
        let id = postTransaction(&harness)
        _ = harness.press(KeyCode.tab)
        harness.decoded.removeAll()
        harness.type("secret")
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
        #expect(harness.press(KeyCode.escape).decision == .swallow)
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
}
