import CoreGraphics
import OpenReactionCore
import Testing

/// Scripted event sequences against the pure gate. Every review finding has
/// at least one scenario here; the harness types with real US-layout key
/// codes and modifier flags, the way the tap would, and answers probes and
/// flushes the way the app layer would.
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
        map["@"] = (19, true)
        return map
    }()

    /// Drives the gate the way the tap and main thread do. Records every
    /// decoder call (live and held) so tests can prove what was read.
    struct Harness {
        var gate = InputGate()
        /// What each event would type, by event id (the tap's CGEvent copy).
        var texts: [Int: String] = [:]
        /// Characters read by the live decoder, in order.
        var decodedLive: [String] = []
        /// Event ids read by the held-event decoder, in order.
        var decodedHeld: [Int] = []
        var nextID = 0
        var secureInput = false
        /// All effects the gate returned, in order.
        var log: [Effect] = []

        var decoded: [String] { decodedLive + decodedHeld.map { texts[$0] ?? "" } }

        @discardableResult
        mutating func press(_ keyCode: UInt16, _ text: String = "", modifiers: KeyModifiers = [], repeat isRepeat: Bool = false) -> InputGate.KeyResult {
            nextID += 1
            let id = nextID
            texts[id] = text
            let event = KeyEvent(keyCode: keyCode, isDown: true, isRepeat: isRepeat, modifiers: modifiers, secureInput: secureInput, id: id)
            let result = gate.key(event) {
                decodedLive.append(text)
                return text
            }
            log += result.effects
            return result
        }

        @discardableResult
        mutating func release(_ keyCode: UInt16, modifiers: KeyModifiers = []) -> InputGate.KeyResult {
            nextID += 1
            let event = KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers, secureInput: secureInput, id: nextID)
            let result = gate.key(event) { "" }
            log += result.effects
            return result
        }

        @discardableResult
        mutating func mouse(_ kind: MouseEventKind, onPicker: Bool = false) -> InputGate.KeyResult {
            nextID += 1
            let result = gate.mouse(kind, id: nextID, onPicker: onPicker)
            log += result.effects
            return result
        }

        /// Types characters with US-layout key codes and Shift where needed.
        @discardableResult
        mutating func type(_ string: String, capsLock: Bool = false) -> [Effect] {
            let start = log.count
            for character in string {
                guard let key = InputGateTests.usLayout[character] else { fatalError("no key for \(character)") }
                let modifiers: KeyModifiers = key.shift ? .shift : []
                let text = capsLock && character.isLetter ? String(character).uppercased() : String(character)
                press(key.code, text, modifiers: modifiers)
                release(key.code, modifiers: modifiers)
            }
            return Array(log[start...])
        }

        /// The most recent probe request, if any.
        var lastProbe: (generation: Int, tokenID: Int?)? {
            log.reversed().lazy.compactMap { if case .requestProbe(let g, let t) = $0 { return (g, t) } else { return nil } }.first
        }

        /// The most recent flush request, if any.
        var lastFlush: Int? {
            log.reversed().lazy.compactMap { if case .postFlush(let id) = $0 { return id } else { return nil } }.first
        }

        /// Answers the latest probe request.
        @discardableResult
        mutating func answerProbe(_ result: FocusResult) -> [Effect] {
            guard let probe = lastProbe else { return [] }
            var read: [Int] = []
            let texts = texts
            var gate = self.gate
            let effects = gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, result) { id in
                read.append(id)
                return texts[id] ?? ""
            }
            self.gate = gate
            decodedHeld += read
            log += effects
            return effects
        }

        /// Acknowledges the current transaction's flush.
        @discardableResult
        mutating func ack() -> [Effect] {
            guard let id = gate.currentTransactionID else { return [] }
            var read: [Int] = []
            let texts = texts
            var gate = self.gate
            let effects = gate.flushAck(transaction: id) { id in
                read.append(id)
                return texts[id] ?? ""
            }
            self.gate = gate
            decodedHeld += read
            log += effects
            return effects
        }

        /// Acknowledges flushes until nothing is held (stops if the gate is
        /// waiting on something other than a flush).
        mutating func settle() {
            var guardCount = 0
            while gate.isHolding, guardCount < 10 {
                let before = log.count
                ack()
                if log.count == before { break }
                guardCount += 1
            }
        }

        @discardableResult
        mutating func run(_ effects: [Effect]) -> [Effect] {
            log += effects
            return effects
        }

        /// The most recent destination check, if any.
        var lastDestinationCheck: (transaction: Int, target: FocusTarget)? {
            log.reversed().lazy.compactMap { if case .checkDestination(let t, let target) = $0 { return (t, target) } else { return nil } }.first
        }

        /// Answers the latest destination check.
        @discardableResult
        mutating func answerDestination(matches: Bool) -> [Effect] {
            guard let check = lastDestinationCheck else { return [] }
            return run(gate.destinationChecked(transaction: check.transaction, matches: matches))
        }
    }

    let anchor = CGRect(x: 10, y: 20, width: 0, height: 18)
    let field = FocusTarget(pid: 42, element: 7)
    var editable: FocusResult { .editable(anchor: anchor, target: field) }

    /// A gate with focus tracking active and the focused field probed editable.
    private func makeHarness(open: Bool = true) -> Harness {
        var harness = Harness()
        if open {
            harness.run(harness.gate.focusTracking(active: true))
            harness.answerProbe(editable)
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

    /// Plain and guarded replays alike (a guarded one is a delayed replay
    /// whose destination was confirmed).
    private func replays(_ effects: [Effect]) -> [[Int]] {
        effects.compactMap {
            switch $0 {
            case .replay(let ids), .replayGuarded(let ids, _): ids
            default: nil
            }
        }
    }

    private func guardedReplays(_ effects: [Effect]) -> [[Int]] {
        effects.compactMap { if case .replayGuarded(let ids, _) = $0 { return ids } else { return nil } }
    }

    private func ended(_ effects: [Effect], _ id: Int, recorded: Bool) -> Bool {
        effects.contains(.transactionEnded(transaction: id, recordUse: recorded))
    }

    /// Types a token: colon (held), probe answered editable, drained, settled.
    private func typeToken(_ harness: inout Harness, _ text: String) {
        harness.type(text)
        harness.answerProbe(editable)
        harness.settle()
    }

    private func harnessWithToken(_ shortcode: String = "tada") -> Harness {
        var harness = makeHarness()
        typeToken(&harness, ":" + shortcode)
        #expect(harness.gate.token?.query == shortcode)
        return harness
    }

    /// Types the closing colon; returns the replacement transaction id.
    private func startReplacement(_ harness: inout Harness) -> Int {
        let effects = harness.type(":")
        let ids = insertions(effects)
        #expect(ids.count == 1)
        return ids[0]
    }

    /// Verifies and commits; returns the transaction id in `posting`.
    private func postReplacement(_ harness: inout Harness) -> Int {
        let id = startReplacement(&harness)
        let effects = harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        #expect(effects == [.post(transaction: id, deleteCount: 6, text: "🎉"), .armWatchdog(transaction: id)])
        let commit = harness.gate.commit(transaction: id, secureInput: false)
        harness.run(commit.effects)
        #expect(commit.proceed)
        return id
    }

    // MARK: H1 — nothing is retained until a token probe says the field is safe

    @Test func colonIsHeldUntilTheTokenProbeAnswers() {
        var harness = makeHarness()
        let colon = harness.press(41, ":", modifiers: .shift)
        #expect(colon.decision == .hold)
        #expect(probes(colon.effects).first?.tokenID != nil)
        // Only the colon itself was read (to see that it is a colon).
        #expect(harness.decodedLive == [":"])
        #expect(harness.release(41, modifiers: .shift).decision == .hold)
        #expect(harness.press(17, "t", modifiers: []).decision == .hold)
        #expect(harness.decodedLive == [":"])
        #expect(harness.gate.token == nil)
    }

    @Test func passwordTypedBeforeALateSecureNotificationIsNeverRetained() {
        // Focus moved to a password field programmatically; the AX notification
        // has not been delivered yet, so the gate still believes the old field.
        var harness = makeHarness()
        harness.type("pa:ss")
        // Each character was looked at for the boundary check and dropped;
        // the colon followed a letter, so nothing was held or kept.
        #expect(!harness.gate.isHolding)
        #expect(harness.gate.token == nil)
        #expect(harness.decodedHeld.isEmpty)

        // With a boundary colon the colon and what follows are held instead.
        let liveBefore = harness.decodedLive.count
        harness.type(" :ss")
        #expect(harness.gate.isHolding)
        // Only the space and the colon were looked at; the `ss` were not read.
        #expect(Array(harness.decodedLive[liveBefore...]) == [" ", ":"])
        #expect(harness.gate.token == nil)
        // The token probe finds the password field: replay untouched, keep nothing.
        let answer = harness.answerProbe(.secure)
        #expect(answer.contains(.postFlush(transaction: 1)))
        let done = harness.ack()
        #expect(replays(done).joined().count == 6) // : s s presses and releases, in order
        #expect(harness.decodedHeld.isEmpty)
        #expect(harness.gate.token == nil)
        #expect(!harness.gate.capturesText)
    }

    @Test func probeTimeoutReplaysHeldKeysUntouched() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.timeout(transaction: 1))
        let done = harness.ack()
        #expect(replays(done).joined().count == 6)
        #expect(harness.decodedHeld.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func staleTokenProbeIsIgnoredAndTheHoldCancelled() {
        var harness = makeHarness()
        harness.type(":ta")
        let probe = harness.lastProbe!
        // Focus moves (mouse) before the probe answers: the hold is cancelled.
        harness.mouse(.down)
        let stale = harness.gate.probeResult(generation: probe.generation, tokenID: probe.tokenID, editable)
        #expect(stale.isEmpty)
        harness.settle()
        #expect(harness.decodedHeld.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func editableProbeInterpretsHeldKeysOnceAndReplaysThem() {
        var harness = makeHarness()
        harness.type(":ta")
        let answer = harness.answerProbe(editable)
        #expect(harness.decodedHeld.count == 3)
        #expect(harness.gate.token?.query == "ta")
        #expect(replays(answer).joined().count == 6)
        harness.settle()
        #expect(!harness.gate.isHolding)
        // The picker shows once the held keys are known to have reached the host.
        #expect(harness.log.contains(.presentPicker(query: "ta", anchor: anchor)))
        // Typing continues live inside the validated token.
        harness.type("d")
        #expect(harness.gate.token?.query == "tad")
    }

    @Test func outsideATokenOnlyTheBoundaryBitIsKept() {
        var harness = makeHarness()
        harness.type("hello")
        #expect(harness.gate.token == nil)
        // A colon after a letter is not a boundary colon: passes, no hold.
        #expect(harness.press(41, ":", modifiers: .shift).decision == .pass)
        #expect(!harness.gate.isHolding)
        harness.release(41, modifiers: .shift)
        harness.type(" ")
        #expect(harness.press(41, ":", modifiers: .shift).decision == .hold)
    }

    @Test(arguments: ["http", "12", "a.b", "user@host"])
    func colonGluedToAWordDoesNotStartAHold(prefix: String) {
        var harness = makeHarness()
        harness.type(prefix)
        #expect(harness.press(41, ":", modifiers: .shift).decision == .pass)
    }

    @Test func backspaceOutsideATokenMakesTheNextColonNonBoundary() {
        var harness = makeHarness()
        harness.type("hi ")
        harness.press(KeyCode.delete)
        harness.release(KeyCode.delete)
        #expect(harness.press(41, ":", modifiers: .shift).decision == .pass)
    }

    @Test func tokenEndingOnSpaceKeepsOnlyTheBoundary() {
        var harness = harnessWithToken()
        harness.type(" ")
        #expect(harness.gate.token == nil)
        #expect(harness.press(41, ":", modifiers: .shift).decision == .hold)
    }

    // MARK: G4 — golden typing with real key codes and Shift

    @Test func fullShortcodeWithShiftedColonsCompletes() {
        var harness = harnessWithToken()
        let effects = harness.type(":")
        #expect(insertions(effects).count == 1)
        #expect(effects.contains(.beginInsertion(transaction: 2, source: .shortcode("tada"), typed: ":tada:", target: field)))
    }

    @Test func plusOneUsesShiftEquals() {
        let harness = harnessWithToken("+1")
        #expect(harness.gate.token?.typed == ":+1")
    }

    @Test func underscoreUsesShiftMinus() {
        let harness = harnessWithToken("thumbs_up")
        #expect(harness.gate.token?.query == "thumbs_up")
    }

    @Test func capsLockTypesUppercaseThatStillMatches() {
        var harness = makeHarness()
        harness.type(":tada", capsLock: true)
        harness.answerProbe(editable)
        harness.settle()
        #expect(harness.gate.token?.query == "tada")
        #expect(harness.gate.token?.typed == ":TADA")
    }

    @Test func autorepeatOfALetterTypesItAgain() {
        var harness = harnessWithToken("ta")
        harness.press(0, "a", repeat: true)
        #expect(harness.gate.token?.query == "taa")
    }

    @Test func shiftAloneDecodesButChordsDoNot() {
        var harness = makeHarness()
        harness.press(41, ":", modifiers: .shift)
        #expect(harness.decodedLive == [":"])
        var second = makeHarness()
        second.press(41, ":", modifiers: [.shift, .command])
        #expect(second.decodedLive.isEmpty)
        #expect(!second.gate.capturesText)
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
        harness.run(harness.gate.focusMayHaveMoved())
        harness.run(harness.gate.probeResult(generation: harness.gate.currentFocusGeneration, tokenID: nil, editable))
        #expect(!harness.gate.capturesText)
        harness.type(":ta")
        #expect(harness.decodedLive.isEmpty)
    }

    @Test func trackingBecomingActiveRequestsAProbeAndThenOpens() {
        var harness = Harness()
        let effects = harness.run(harness.gate.focusTracking(active: true))
        #expect(probes(effects).count == 1)
        harness.answerProbe(editable)
        #expect(harness.gate.capturesText)
    }

    @Test func losingTrackingClosesCaptureAndForgets() {
        var harness = harnessWithToken("ta")
        let effects = harness.run(harness.gate.focusTracking(active: false))
        #expect(effects.contains(.dismissPicker))
        #expect(!harness.gate.capturesText)
        #expect(harness.gate.token == nil)
        #expect(probes(effects).isEmpty)
    }

    // MARK: R1 — capture closes before any focus-moving event passes

    @Test func nothingIsDecodedWhileClosed() {
        var harness = makeHarness(open: false)
        harness.type(":tada:")
        #expect(harness.decodedLive.isEmpty)
        #expect(!harness.gate.isHolding)
    }

    @Test(arguments: [KeyCode.tab, KeyCode.return, KeyCode.keypadEnter])
    func tabOrReturnPassingToTheHostClosesCaptureBeforeMoreTyping(keyCode: UInt16) {
        var harness = makeHarness()
        harness.type("abc")
        let result = harness.press(keyCode)
        #expect(result.decision == .pass)
        #expect(!harness.gate.capturesText)
        #expect(probes(result.effects).count == 1)
        harness.release(keyCode)
        harness.decodedLive.removeAll()
        harness.type("hunter2")
        #expect(harness.decodedLive.isEmpty)
    }

    @Test func mouseDownClosesCaptureSynchronously() {
        var harness = makeHarness()
        let result = harness.mouse(.down)
        #expect(result.decision == .pass)
        #expect(!harness.gate.capturesText)
        #expect(probes(result.effects).count == 1)
        harness.type(":x")
        #expect(harness.decodedLive.isEmpty)
    }

    @Test func clickOnThePickerChangesNothing() {
        var harness = harnessWithToken()
        #expect(harness.mouse(.down, onPicker: true).effects.isEmpty)
        #expect(harness.gate.capturesText)
    }

    @Test(arguments: [KeyModifiers.command, .control, .option])
    func modifierChordsCloseCaptureAndAreNotDecoded(modifier: KeyModifiers) {
        var harness = makeHarness()
        let result = harness.press(0, "a", modifiers: modifier)
        #expect(result.decision == .pass)
        #expect(harness.decodedLive.isEmpty)
        #expect(!harness.gate.capturesText)
    }

    @Test func secureInputIsNeverDecodedAndClearsTyping() {
        var harness = harnessWithToken("ta")
        harness.secureInput = true
        harness.decodedLive.removeAll()
        let result = harness.press(2, "d")
        #expect(result.decision == .pass)
        #expect(harness.decodedLive.isEmpty)
        #expect(harness.gate.token == nil)
    }

    @Test func activationClosesCaptureUntilReprobed() {
        var harness = makeHarness()
        harness.run(harness.gate.focusMayHaveMoved())
        #expect(!harness.gate.capturesText)
        harness.type(":ta")
        #expect(harness.decodedLive.isEmpty)
    }

    @Test func excludedAppNeverHoldsOrProbes() {
        var harness = makeHarness()
        harness.gate.frontmostApp(excluded: true)
        let effects = harness.type(":tada:")
        #expect(probes(effects).isEmpty)
        #expect(!harness.gate.isHolding)
    }

    // MARK: G3 / H2 — commit at execution time; mouse held after commit

    @Test func committedReplacementPostsThenDrainsAndRecords() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        let done = harness.ack()
        #expect(ended(done, id, recorded: true))
        #expect(!harness.gate.isHolding)
        // The emoji is a boundary: a new colon starts a hold.
        #expect(harness.press(41, ":", modifiers: .shift).decision == .hold)
    }

    @Test func mouseDownAfterCommitIsHeldUntilTheFlushIsAcknowledged() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        // Commit returned; the deletes may not have been posted yet.
        #expect(harness.mouse(.down).decision == .hold)
        #expect(harness.mouse(.drag).decision == .hold)
        #expect(harness.mouse(.up).decision == .hold)
        let mouseIDs = [harness.nextID - 2, harness.nextID - 1, harness.nextID]
        let drain = harness.ack()
        // Replayed after our text, and the click still closes capture.
        #expect(replays(drain) == [mouseIDs])
        #expect(!harness.gate.capturesText)
        #expect(ended(harness.ack(), id, recorded: true))
    }

    @Test func mouseDownMidDeleteLoopIsOrderedAfterTheReplacement() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        harness.mouse(.down)
        let ids = [harness.nextID - 1, harness.nextID]
        let drain = harness.ack()
        #expect(replays(drain) == [ids])
        _ = id
    }

    @Test func mouseDownBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        let effects = harness.mouse(.down).effects
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
        #expect(ended(harness.ack(), id, recorded: false))
    }

    @Test func focusChangeBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        harness.run(harness.gate.focusMayHaveMoved())
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func pauseBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        harness.run(harness.gate.tapStopped())
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func secureInputAtCommitTimeRefusesAndCancels() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        let commit = harness.gate.commit(transaction: id, secureInput: true)
        harness.run(commit.effects)
        #expect(!commit.proceed)
        #expect(commit.effects.contains(.postFlush(transaction: id)))
        #expect(ended(harness.ack(), id, recorded: false))
    }

    @Test func timeoutBeforeCommitRefusesTheCommit() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        harness.run(harness.gate.timeout(transaction: id))
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func trackingLostBeforeCommitCancels() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        harness.run(harness.gate.focusTracking(active: false))
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
    }

    @Test func commitIsOnlyValidOnceAndOnlyWhenAuthorized() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        #expect(harness.gate.commit(transaction: id, secureInput: false).proceed)
        #expect(!harness.gate.commit(transaction: id, secureInput: false).proceed)
        #expect(!harness.gate.commit(transaction: id + 1, secureInput: false).proceed)
    }

    @Test func lateVerifyAfterTimeoutPostsNothing() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        let timeout = harness.run(harness.gate.timeout(transaction: id))
        #expect(posts(timeout).isEmpty)
        #expect(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")).isEmpty)
        #expect(ended(harness.ack(), id, recorded: false))
    }

    @Test func refusedVerificationPostsNothingAndForgets() {
        var harness = harnessWithToken()
        let id = startReplacement(&harness)
        let effects = harness.run(harness.gate.verifyResult(transaction: id, .refused))
        #expect(posts(effects).isEmpty)
        #expect(ended(harness.ack(), id, recorded: false))
        #expect(harness.gate.token == nil)
    }

    @Test func staleTransactionAnswersAreIgnored() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.ack()
        #expect(harness.gate.flushAck(transaction: id).isEmpty)
        #expect(harness.gate.timeout(transaction: id).isEmpty)
        #expect(harness.gate.verifyResult(transaction: id + 5, .keystrokes(text: "x")).isEmpty)
    }

    // MARK: H3 — releases wait for their replayed press to be acknowledged

    @Test func releaseArrivingAfterReplayWasEnqueuedIsHeldUntilAcknowledged() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        #expect(harness.press(7, "x").decision == .hold)
        let xDown = harness.nextID
        let drain = harness.ack()
        #expect(replays(drain) == [[xDown]])
        // The replay is only enqueued; the physical release must not overtake it.
        #expect(harness.release(7).decision == .hold)
        let xUp = harness.nextID
        let drain2 = harness.ack()
        #expect(replays(drain2) == [[xUp]])
        #expect(ended(harness.ack(), id, recorded: true))
    }

    @Test func releaseAfterAcknowledgedReplayPassesThrough() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        harness.ack()
        harness.ack() // the replay's flush: x-down delivered
        #expect(ended(harness.log, id, recorded: true))
        #expect(harness.release(7).decision == .pass)
    }

    @Test func releaseThenNewPressOfTheSameKeyAreBothHeldInOrder() {
        var harness = harnessWithToken()
        _ = postReplacement(&harness)
        harness.press(7, "x")
        harness.release(7)
        harness.press(7, "x")
        let ids = [harness.nextID - 2, harness.nextID - 1, harness.nextID]
        #expect(replays(harness.ack()) == [ids])
        // The second press is still in flight: its release is held.
        #expect(harness.release(7).decision == .hold)
    }

    @Test func recoveryReplayKeepsReleasesHeldUntilAcknowledged() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        harness.run(harness.gate.timeout(transaction: id))
        let recover = harness.run(harness.gate.timeout(transaction: id))
        #expect(replays(recover).count == 1)
        #expect(harness.release(7).decision == .hold)
        harness.ack()
        #expect(replays(harness.log.suffix(4)).contains([harness.nextID]))
    }

    @Test func stopReplaysOwedEventsInOrderWithoutSyntheticReleases() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let effects = harness.run(harness.gate.tapStopped())
        #expect(replays(effects) == [[harness.nextID]])
        #expect(ended(effects, id, recorded: false))
        #expect(!harness.gate.isHolding)
        // The physical release now passes directly.
        #expect(harness.release(7).decision == .pass)
    }

    @Test func giveUpReplaysEverythingOwedInOrder() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        harness.run(harness.gate.timeout(transaction: id))
        harness.run(harness.gate.timeout(transaction: id))
        harness.press(16, "y")
        var last: [Effect] = []
        while harness.gate.isHolding { last = harness.run(harness.gate.timeout(transaction: id)) }
        #expect(replays(last) == [[harness.nextID]])
        #expect(ended(last, id, recorded: false))
    }

    // MARK: H4 — recovery resets history to a safe boundary

    @Test func tokenAfterAcknowledgedRecoveryStillTriggers() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.type(" ")
        harness.run(harness.gate.timeout(transaction: id))
        harness.run(harness.gate.timeout(transaction: id)) // recovery replays the space
        let done = harness.ack()
        #expect(ended(done, id, recorded: true))
        #expect(!harness.gate.isHolding)
        #expect(harness.press(41, ":", modifiers: .shift).decision == .hold)
        harness.release(41, modifiers: .shift)
        harness.type("sm")
        harness.answerProbe(editable)
        #expect(harness.gate.token?.query == "sm")
    }

    @Test func recoveryAcknowledgedResumesNormalDraining() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.run(harness.gate.timeout(transaction: id))
        harness.run(harness.gate.timeout(transaction: id))
        #expect(ended(harness.ack(), id, recorded: true))
    }

    @Test func tapInterruptionRecoversInsteadOfReopening() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let effects = harness.run(harness.gate.tapInterrupted())
        #expect(replays(effects) == [[harness.nextID]])
        #expect(effects.contains(.postFlush(transaction: id)))
        #expect(harness.gate.isHolding)
        #expect(!harness.gate.capturesText)
    }

    // MARK: R3 — watchdog outlives posting; drains keep order

    @Test func watchdogStaysArmedUntilTheDrainCompletes() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let drain = harness.ack()
        #expect(drain.contains(.armWatchdog(transaction: id)))
        #expect(!drain.contains { if case .transactionEnded = $0 { return true } else { return false } })
        #expect(ended(harness.ack(), id, recorded: true))
    }

    @Test func keysArrivingDuringTheDrainAreHeldUntilTheNextAck() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        #expect(harness.press(0, "a").decision == .hold)
        #expect(replays(harness.ack()) == [[harness.nextID]])
        #expect(harness.press(11, "b").decision == .hold)
        #expect(replays(harness.ack()) == [[harness.nextID]])
        #expect(ended(harness.ack(), id, recorded: true))
    }

    @Test func releaseOfAKeyPressedBeforeTheHoldPassesThrough() {
        var harness = harnessWithToken()
        harness.press(41, ":", modifiers: .shift)
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
        let id = insertions(down.effects)[0]
        harness.run(harness.gate.verifyResult(transaction: id, .keystrokes(text: "🎉")))
        harness.run(harness.gate.commit(transaction: id, secureInput: false).effects)
        harness.settle()
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

    @Test func stopClearsOwnership() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        harness.press(KeyCode.escape)
        harness.run(harness.gate.tapStopped())
        harness.gate.pickerVisibility(false)
        #expect(harness.release(KeyCode.escape).decision == .pass)
    }

    // MARK: R6 / G7 — drained keys go through the trigger logic exactly once

    @Test func colonTypedDuringAHoldIsProbedAfterTheTransaction() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.type(" :sm")
        let drain = harness.ack()
        // The space is replayed; the colon and after wait for their own probe.
        #expect(replays(drain).first?.count == 2)
        let done = harness.ack()
        #expect(ended(done, id, recorded: true))
        #expect(probes(done).first?.tokenID != nil)
        #expect(harness.gate.isHolding)
        harness.answerProbe(editable)
        #expect(harness.gate.token?.query == "sm")
        harness.settle()
        #expect(!harness.gate.isHolding)
    }

    @Test func drainedTextKeepsWordBoundariesCorrect() {
        var harness = harnessWithToken()
        _ = postReplacement(&harness)
        harness.type("http")
        harness.settle()
        // Host text is 🎉http; a colon here follows a letter and must not trigger.
        #expect(harness.press(41, ":", modifiers: .shift).decision == .pass)
    }

    @Test func closingColonDrainedDuringATransactionStartsTheNextOneInOrder() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        // A whole second shortcode plus a key, all while the first is in flight.
        harness.type(" :tada:x")
        let xDown = harness.nextID - 1
        harness.settle() // first replacement drains up to the colon
        #expect(ended(harness.log, id, recorded: true))
        // The colon's token probe answers; the drain then completes the
        // shortcode and defers to a second replacement.
        harness.answerProbe(editable)
        harness.settle()
        let second = insertions(harness.log).last!
        #expect(second != id)
        #expect(!replays(harness.log).joined().contains(xDown))
        harness.run(harness.gate.verifyResult(transaction: second, .keystrokes(text: "🎉")))
        harness.run(harness.gate.commit(transaction: second, secureInput: false).effects)
        harness.ack()
        #expect(replays(harness.log).joined().contains(xDown))
    }

    @Test func drainedKeysAreNotInterpretedIfAFocusMovingKeyPrecedesThem() {
        var harness = harnessWithToken()
        _ = postReplacement(&harness)
        let readBefore = harness.decodedHeld.count
        harness.press(KeyCode.tab)
        harness.type("secret")
        harness.settle()
        #expect(harness.decodedHeld.count == readBefore)
        #expect(!harness.gate.capturesText)
    }

    // MARK: L5 — a deliberate stop drains in order before the tap goes

    @Test func shutdownDuringAProbeDrainsHeldKeysBeforeAnyNewInput() {
        var harness = makeHarness()
        harness.type(":ta")
        let held = Array(1...6)
        // Lock/pause: nothing new is authorized, the held keys are still owed.
        let effects = harness.run(harness.gate.beginShutdown())
        #expect(effects.contains(.postFlush(transaction: 1)))
        #expect(harness.gate.isHolding)
        #expect(!harness.gate.capturesText)
        // A Backspace typed now must not overtake the colon: it is held too.
        #expect(harness.press(KeyCode.delete).decision == .hold)
        let backspace = harness.nextID
        let drain = harness.ack()
        #expect(replays(drain) == [held + [backspace]])
        #expect(harness.decodedHeld.isEmpty)
        harness.settle()
        #expect(!harness.gate.isHolding)
        // Only now is the tap uninstalled.
        let stopped = harness.run(harness.gate.tapStopped())
        #expect(replays(stopped).isEmpty)
    }

    @Test func shutdownDuringPostingLetsTheReplacementFinishInOrder() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let xDown = harness.nextID
        harness.run(harness.gate.beginShutdown())
        #expect(harness.gate.isHolding)
        // The committed replacement still completes and x follows it.
        let drain = harness.ack()
        #expect(replays(drain) == [[xDown]])
        let done = harness.ack()
        #expect(ended(done, id, recorded: true))
        #expect(!harness.gate.isHolding)
    }

    @Test func nothingStartsWhileShuttingDown() {
        var harness = makeHarness()
        harness.run(harness.gate.beginShutdown())
        #expect(!harness.gate.isHolding)
        #expect(harness.press(41, ":", modifiers: .shift).decision == .pass)
        #expect(harness.decodedLive.isEmpty)
        // A late probe answer for the old generation opens nothing.
        harness.answerProbe(editable)
        #expect(!harness.gate.capturesText)
    }

    @Test func shutdownDropsADeferredColonInsteadOfProbingIt() {
        var harness = harnessWithToken()
        _ = postReplacement(&harness)
        harness.type(" :sm")
        let mark = harness.log.count
        harness.run(harness.gate.beginShutdown())
        harness.settle()
        #expect(!harness.gate.isHolding)
        let after = Array(harness.log[mark...])
        #expect(probes(after).isEmpty)
        #expect(replays(after).joined().count == 8)
    }

    // MARK: P0-3 — shutdown ends only when the tap acknowledges delivery

    @Test func shutdownWaitsForTheReplayToBeAcknowledgedBeforeNewInputGoesOut() {
        var harness = makeHarness()
        harness.type(":ta")
        let held = Array(1...6)
        harness.run(harness.gate.beginShutdown())
        // The held keys are replayed with a flush behind them.
        let drain = harness.ack()
        #expect(replays(drain) == [held])
        #expect(harness.lastFlush == 1)
        #expect(harness.gate.isHolding)
        // Typed while that replay is in flight: held behind it, not passed.
        #expect(harness.press(KeyCode.delete).decision == .hold)
        let backspace = harness.nextID
        #expect(harness.release(KeyCode.delete).decision == .hold)
        #expect(harness.gate.isHolding)
        // The replay's flush comes back: only now is the Backspace replayed.
        let next = harness.ack()
        #expect(replays(next) == [[backspace, backspace + 1]])
        #expect(harness.gate.isHolding)
        // And it, in turn, is acknowledged before the gate reports done.
        let done = harness.ack()
        #expect(ended(done, 1, recorded: false))
        #expect(!harness.gate.isHolding)
        #expect(harness.decodedHeld.isEmpty)
    }

    @Test func trackingAndProbesDuringShutdownNeverReopenCapture() {
        var harness = makeHarness()
        harness.run(harness.gate.beginShutdown())
        #expect(harness.run(harness.gate.focusTracking(active: true)).isEmpty)
        #expect(harness.run(harness.gate.focusTracking(active: false)).isEmpty)
        // Even a probe answer for the current generation opens nothing.
        let generation = harness.gate.currentFocusGeneration
        harness.run(harness.gate.probeResult(generation: generation, tokenID: nil, editable))
        #expect(!harness.gate.capturesText)
        #expect(harness.press(41, ":", modifiers: .shift).decision == .pass)
        #expect(harness.decodedLive.isEmpty)
        #expect(!harness.gate.isHolding)
        // The same while something is still draining.
        var draining = makeHarness()
        draining.type(":ta")
        draining.run(draining.gate.beginShutdown())
        draining.run(draining.gate.focusTracking(active: true))
        draining.run(draining.gate.probeResult(generation: draining.gate.currentFocusGeneration, tokenID: nil, editable))
        #expect(!draining.gate.capturesText)
        #expect(probes(draining.log.suffix(2)).isEmpty)
        draining.settle()
        #expect(!draining.gate.isHolding)
        #expect(!draining.gate.capturesText)
    }

    @Test func timeoutsDuringShutdownNeverDecideDelivery() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let xDown = harness.nextID
        harness.run(harness.gate.beginShutdown())
        // Many missed acknowledgements: the gate keeps asking, never gives up.
        var replayed: [[Int]] = []
        for _ in 0..<(InputGate.recoveryAttempts + 5) {
            let effects = harness.run(harness.gate.timeout(transaction: id))
            replayed += replays(effects)
            #expect(effects.contains(.postFlush(transaction: id)))
            #expect(!effects.contains { if case .transactionEnded = $0 { return true } else { return false } })
            #expect(harness.gate.isHolding)
        }
        #expect(replayed == [[xDown]]) // replayed once, then only re-flushed
        // Something typed meanwhile waits behind the replay too.
        #expect(harness.press(8, "c").decision == .hold)
        let cDown = harness.nextID
        // The stream answers: the new key goes out, and its flush ends it.
        let drain = harness.ack()
        #expect(replays(drain) == [[cDown]])
        let done = harness.ack()
        #expect(ended(done, id, recorded: true)) // the flush came back: the replacement got through
        #expect(!harness.gate.isHolding)
    }

    @Test func shutdownOutcomeIsDeliveredOnlyThroughAcknowledgement() {
        var idle = makeHarness()
        idle.run(idle.gate.beginShutdown())
        #expect(idle.gate.shutdownOutcome == .delivered) // nothing owed
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        #expect(harness.gate.shutdownOutcome == nil)
        harness.ack() // replay + flush
        #expect(harness.gate.shutdownOutcome == nil) // replay enqueued, not acknowledged
        harness.ack()
        #expect(harness.gate.shutdownOutcome == .delivered)
        #expect(!harness.gate.isHolding)
        harness.run(harness.gate.tapStopped())
        #expect(harness.gate.shutdownOutcome == nil)
    }

    @Test func anOSDisabledTapEndsAShutdownOnlyOnceTheReplayHasRun() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.press(KeyCode.delete)
        let backspace = harness.nextID
        // macOS disabled the tap: the acknowledgement may never come. What is
        // owed is replayed in order — and the gate keeps holding until the app
        // layer confirms that the replay actually ran.
        let asked = harness.run(harness.gate.tapInterrupted())
        // First: is the focus still where the input was typed? Nothing is
        // replayed until the app layer says so.
        #expect(asked == [.checkDestination(transaction: 1, target: field)])
        #expect(harness.gate.isHolding)
        let effects = harness.answerDestination(matches: true)
        #expect(replays(effects) == [Array(1...6) + [backspace]])
        #expect(effects.last == .confirmReplay(transaction: 1))
        #expect(!ended(effects, 1, recorded: false))
        #expect(harness.gate.isHolding)
        #expect(harness.gate.shutdownOutcome == nil)
        // A fresh Backspace (the physical release, then a new press) while the
        // replay is queued: held behind it, never passed.
        #expect(harness.release(KeyCode.delete).decision == .hold)
        #expect(harness.press(KeyCode.delete).decision == .hold)
        let fresh = [backspace + 1, backspace + 2]
        // Timeouts and late flush acks change nothing now.
        #expect(harness.run(harness.gate.timeout(transaction: 1)).isEmpty)
        #expect(harness.ack().isEmpty)
        // The replay ran: the fresh input is checked and goes out after it.
        #expect(harness.run(harness.gate.replayExecuted(transaction: 1)) == [.checkDestination(transaction: 1, target: field)])
        let next = harness.answerDestination(matches: true)
        #expect(replays(next) == [fresh])
        #expect(next.last == .confirmReplay(transaction: 1))
        #expect(harness.gate.isHolding)
        let done = harness.run(harness.gate.replayExecuted(transaction: 1))
        #expect(ended(done, 1, recorded: false))
        #expect(!harness.gate.isHolding)
        #expect(harness.gate.shutdownOutcome == .interrupted)
        #expect(probes(effects + next + done).isEmpty)
        #expect(!harness.gate.capturesText)
    }

    @Test func aFlushThatCannotBePostedEndsAShutdownAsFailedAfterTheOrderedReplay() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let xDown = harness.nextID
        harness.run(harness.gate.beginShutdown())
        // The insertion queue could not create the flush marker.
        #expect(harness.run(harness.gate.streamFailed(transaction: id)) == [.checkDestination(transaction: id, target: field)])
        let effects = harness.answerDestination(matches: true)
        #expect(replays(effects) == [[xDown]])
        #expect(effects.last == .confirmReplay(transaction: id))
        #expect(harness.gate.isHolding)
        #expect(harness.gate.shutdownOutcome == nil)
        #expect(harness.press(8, "c").decision == .hold)
        let cDown = harness.nextID
        harness.run(harness.gate.replayExecuted(transaction: id))
        let next = harness.answerDestination(matches: true)
        #expect(replays(next) == [[cDown]])
        let done = harness.run(harness.gate.replayExecuted(transaction: id))
        #expect(ended(done, id, recorded: false))
        #expect(harness.gate.shutdownOutcome == .failed)
        #expect(!harness.gate.isHolding)
    }

    @Test func aFlushThatCannotBePostedOutsideAShutdownGivesUpInOrder() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let xDown = harness.nextID
        let effects = harness.run(harness.gate.streamFailed(transaction: id))
        #expect(replays(effects) == [[xDown]])
        #expect(ended(effects, id, recorded: false))
        #expect(!harness.gate.isHolding)
        #expect(!harness.gate.capturesText) // probed again before anything is trusted
        #expect(harness.gate.shutdownOutcome == nil)
    }

    @Test func abandoningAcknowledgementsReplaysInOrderAndEndsFailedOnceRun() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.press(KeyCode.delete)
        let backspace = harness.nextID
        // The app layer stopped waiting for acks: same protocol as an
        // interruption, outcome .failed.
        harness.run(harness.gate.acknowledgementAbandoned())
        let effects = harness.answerDestination(matches: true)
        #expect(replays(effects) == [Array(1...6) + [backspace]])
        #expect(effects.last == .confirmReplay(transaction: 1))
        #expect(harness.gate.isHolding)
        #expect(harness.press(7, "x").decision == .hold)
        let x = harness.nextID
        #expect(harness.run(harness.gate.acknowledgementAbandoned()).isEmpty) // already replaying
        harness.run(harness.gate.replayExecuted(transaction: 1))
        let next = harness.answerDestination(matches: true)
        #expect(replays(next) == [[x]])
        harness.run(harness.gate.replayExecuted(transaction: 1))
        #expect(harness.gate.shutdownOutcome == .failed)
        #expect(!harness.gate.isHolding)
        // Outside a shutdown it means nothing.
        var idle = makeHarness()
        #expect(idle.run(idle.gate.acknowledgementAbandoned()).isEmpty)
    }

    @Test func replayConfirmationsForAnotherTransactionAreIgnored() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.run(harness.gate.tapInterrupted())
        #expect(harness.run(harness.gate.destinationChecked(transaction: 99, matches: true)).isEmpty)
        harness.answerDestination(matches: true)
        #expect(harness.run(harness.gate.replayExecuted(transaction: 99)).isEmpty)
        #expect(harness.gate.isHolding)
    }

    // MARK: F3 — a delayed replay goes only where the input was typed

    @Test func heldInputIsDroppedWhenTheFocusedFieldChangedBeforeADelayedReplay() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.press(KeyCode.delete)
        let backspace = harness.nextID
        harness.run(harness.gate.tapInterrupted())
        #expect(harness.lastDestinationCheck?.target == field)
        // Focus moved (another app, a dialog, a password field): nothing is
        // posted there. The held events are released and the user is told.
        let effects = harness.answerDestination(matches: false)
        #expect(replays(effects).isEmpty)
        #expect(effects == [.drop(eventIDs: Array(1...6) + [backspace]), .inputLost(eventCount: 7), .confirmReplay(transaction: 1)])
        #expect(harness.gate.isHolding) // still owns the stream until the queue confirms
        let done = harness.run(harness.gate.replayExecuted(transaction: 1))
        #expect(ended(done, 1, recorded: false))
        #expect(harness.gate.shutdownOutcome == .interrupted)
        #expect(!harness.gate.isHolding)
    }

    @Test func everyDelayedReplayBatchIsCheckedAgainstTheOriginalField() {
        var harness = harnessWithToken()
        let id = postReplacement(&harness)
        harness.press(7, "x")
        let x = harness.nextID
        harness.run(harness.gate.beginShutdown())
        harness.run(harness.gate.streamFailed(transaction: id))
        #expect(harness.lastDestinationCheck?.target == field) // the replacement's target
        harness.answerDestination(matches: true)
        harness.press(8, "c")
        let c = harness.nextID
        // The next batch is checked on its own; this time the field changed.
        harness.run(harness.gate.replayExecuted(transaction: id))
        #expect(harness.lastDestinationCheck?.transaction == id)
        let effects = harness.answerDestination(matches: false)
        #expect(effects.contains(.drop(eventIDs: [c])))
        #expect(effects.contains(.inputLost(eventCount: 1)))
        #expect(!effects.contains(.replay(eventIDs: [c])))
        #expect(!effects.contains(.replay(eventIDs: [x])))
        harness.run(harness.gate.replayExecuted(transaction: id))
        #expect(harness.gate.shutdownOutcome == .failed)
    }

    @Test func aConfirmedDelayedReplayIsGuardedSoTheAppLayerChecksAgainWhenItRuns() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.run(harness.gate.tapInterrupted())
        let effects = harness.answerDestination(matches: true)
        #expect(guardedReplays(effects) == [Array(1...6)])
        #expect(effects.contains(.replayGuarded(eventIDs: Array(1...6), transaction: 1)))
        // Ordinary acknowledged drains are not guarded: the tap acknowledges them.
        var acked = makeHarness()
        acked.type(":ta")
        acked.run(acked.gate.beginShutdown())
        let drain = acked.ack()
        #expect(guardedReplays(drain).isEmpty)
        #expect(replays(drain) == [Array(1...6)])
    }

    // MARK: G5 — the app's own windows stay usable; the user can discard

    @Test func inputAimedAtOurOwnWindowsIsNeverHeldWhileShuttingDown() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.run(harness.gate.tapInterrupted())
        #expect(harness.gate.isHolding)
        // A click and a key press on the stuck-input panel pass straight through.
        harness.nextID += 1
        let click = harness.gate.mouse(.down, id: harness.nextID, onPicker: false, targetsOwnApp: true)
        #expect(click.decision == .pass)
        harness.nextID += 1
        let own = KeyEvent(keyCode: KeyCode.return, isDown: true, id: harness.nextID, targetsOwnApp: true)
        #expect(harness.gate.key(own) { "" }.decision == .pass)
        // Everything aimed elsewhere still waits behind the replay.
        #expect(harness.mouse(.down).decision == .hold)
        #expect(harness.press(KeyCode.return).decision == .hold)
        // Outside a shutdown our own windows go through the gate like any other
        // (onboarding's practice field relies on it).
        var normal = makeHarness()
        normal.nextID += 1
        let colon = KeyEvent(keyCode: 41, isDown: true, modifiers: .shift, id: normal.nextID, targetsOwnApp: true)
        #expect(normal.gate.key(colon) { ":" }.decision == .hold)
    }

    @Test func discardingHeldInputEndsTheShutdownFailedAndTellsTheUser() {
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        harness.run(harness.gate.tapInterrupted())
        harness.answerDestination(matches: true) // replay queued but never run
        harness.press(KeyCode.delete)
        let backspace = harness.nextID
        // Outside a shutdown discarding means nothing.
        var normal = harnessWithToken()
        #expect(normal.run(normal.gate.discardHeld()).isEmpty)
        // The user's choice: drop what is still held, stop now.
        let effects = harness.run(harness.gate.discardHeld())
        #expect(effects == [.drop(eventIDs: [backspace]), .inputLost(eventCount: 1), .transactionEnded(transaction: 1, recordUse: false), .dismissPicker])
        #expect(!harness.gate.isHolding)
        #expect(harness.gate.shutdownOutcome == .failed)
        #expect(harness.run(harness.gate.replayExecuted(transaction: 1)).isEmpty) // the late confirmation is moot
    }

    @Test func aDelayedReplayWithNoKnownOriginIsDropped() {
        // Capture closed before the transaction had an origin cannot happen for
        // a real token (a colon starts one only in an open capture); a held
        // mouse-only transaction still answers "changed" and drops.
        var harness = makeHarness()
        harness.type(":ta")
        harness.run(harness.gate.beginShutdown())
        // Answers for the wrong transaction or outside a check are ignored.
        #expect(harness.run(harness.gate.destinationChecked(transaction: 1, matches: true)).isEmpty)
        harness.run(harness.gate.tapInterrupted())
        #expect(harness.run(harness.gate.replayExecuted(transaction: 1)).isEmpty) // waiting for the check, not a run
        #expect(harness.gate.isHolding)
    }

    // MARK: Picker commands

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
        #expect(insertions(harness.type(":")).isEmpty)
    }

    @Test func clickingARowInsertsTheSelection() {
        var harness = harnessWithToken()
        harness.gate.pickerVisibility(true)
        let effects = harness.run(harness.gate.pickerClicked())
        #expect(effects.contains(.beginInsertion(transaction: 2, source: .selection, typed: ":tada", target: field)))
    }

    @Test func pickerAppearsOnlyWithTwoCharacters() {
        var harness = makeHarness()
        harness.type(":t")
        let answer = harness.answerProbe(editable)
        #expect(!answer.contains { if case .presentPicker = $0 { return true } else { return false } })
        harness.settle()
        #expect(harness.type("a").contains(.presentPicker(query: "ta", anchor: anchor)))
    }
}
