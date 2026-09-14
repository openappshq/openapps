import CoreGraphics

/// Virtual key codes OpenReaction interprets (ANSI layout independent).
public enum KeyCode {
    public static let `return`: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let help: UInt16 = 114
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// One physical keyboard event as seen by the tap, before any decoding.
public struct KeyEvent: Equatable, Sendable {
    public let keyCode: UInt16
    public let isDown: Bool
    public let isRepeat: Bool
    public let modifiers: KeyModifiers
    /// `IsSecureEventInputEnabled()` at the time of the event.
    public let secureInput: Bool
    /// Identifies the app layer's copy of the event, for replay.
    public let id: Int

    public init(keyCode: UInt16, isDown: Bool, isRepeat: Bool = false, modifiers: KeyModifiers = [], secureInput: Bool = false, id: Int) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.modifiers = modifiers
        self.secureInput = secureInput
        self.id = id
    }
}

/// Identifies the element that had focus, so a replacement can be refused
/// when focus moved elsewhere in the meantime.
public struct FocusTarget: Hashable, Sendable {
    public let pid: Int32
    /// Stable identity of the accessibility element within its app.
    public let element: UInt

    public init(pid: Int32, element: UInt) {
        self.pid = pid
        self.element = element
    }
}

/// What is known about the element that has keyboard focus.
public enum FocusResult: Equatable, Sendable {
    /// A password field or similar. Nothing may be observed or inserted.
    case secure
    /// Editable text; `anchor` is where the picker goes (AppKit coordinates).
    case editable(anchor: CGRect, target: FocusTarget)
    /// The focused element could not be read (no focus, timeout, no
    /// Accessibility access). Treated as unsafe: nothing is captured or inserted.
    case unavailable
}

/// Outcome of verifying a replacement target right before changing text.
/// Verification is read-only; the host is never touched by it.
public enum VerifyResult: Equatable, Sendable {
    /// The typed token is right before an empty caret: delete it with key
    /// events and type `text`.
    case keystrokes(text: String)
    /// The field, selection or text could not be confirmed. Nothing may change.
    case refused
}

/// What the gate wants the app layer to do. Effects are executed in order.
public enum GateEffect: Equatable, Sendable {
    /// Query the focused element and call `probeResult` with these ids.
    case requestProbe(generation: Int, tokenID: Int?)
    case presentPicker(query: String, anchor: CGRect)
    case dismissPicker
    case moveSelection(by: Int)
    /// Resolve the text to insert, verify the target (read-only) while keys
    /// are held, then call `verifyResult`.
    case beginInsertion(transaction: Int, source: InsertionSource, typed: String, target: FocusTarget)
    /// Enqueue the replacement. When it is about to run, call `commit`; only
    /// if that returns true post `deleteCount` Deletes, `text`, and the flush.
    case post(transaction: Int, deleteCount: Int, text: String)
    /// Post only the flush marker for the transaction.
    case postFlush(transaction: Int)
    /// Post the app layer's copies of these held events, in order, as passthrough.
    case replay(eventIDs: [Int])
    /// Release the app layer's copies of these held events.
    case drop(eventIDs: [Int])
    /// Post key-ups for presses that were replayed but whose releases may
    /// have reached the host already (recovery only).
    case release(keyCodes: [UInt16])
    /// Send a synthetic press of this key; the tap swallowed a physical one
    /// the picker could not use.
    case repost(keyCode: UInt16)
    case armWatchdog(transaction: Int)
    /// The transaction is over. `recordUse` is true only for a completed replacement.
    case transactionEnded(transaction: Int, recordUse: Bool)
}

public enum InsertionSource: Equatable, Sendable {
    /// The picker's selected suggestion.
    case selection
    /// The emoji for a fully typed `:shortcode:`.
    case shortcode(String)
}

/// Decides what happens to every keyboard and mouse event, when text may be
/// decoded, when the picker shows, and how a text replacement runs.
///
/// Pure and single-threaded: the app layer feeds it an ordered stream of
/// inputs (from the tap thread and the main thread, under one lock) and runs
/// the effects it returns. Every asynchronous answer carries the generation or
/// transaction it belongs to; stale answers are ignored.
///
/// ```mermaid
/// stateDiagram-v2
///     [*] --> Closed
///     Closed --> Closed: keys pass undecoded / mouse / focus event
///     Closed --> Open: probeResult(gen == current, editable) while focus tracking is active
///     Open --> Closed: mouse down · Tab/Return/chord passes · activation · secure input · probe not editable · tracking lost
///     Open --> Open: typed text → TriggerMachine → picker
///     state Transaction {
///         [*] --> Verifying: insert requested (keys held)
///         Verifying --> Authorized: verifyResult keystrokes
///         Authorized --> Posting: commit (checked again at execution time)
///         Verifying --> Draining: refused · cancel
///         Authorized --> Draining: cancel · commit refused
///         Posting --> Draining: flushAck
///         Draining --> Draining: flushAck with new held keys (replay again)
///         Draining --> [*]: flushAck, nothing held (reopen)
///         Posting --> Recovering: repeated timeout / tap re-enabled (replay, flush)
///         Recovering --> Draining: flushAck
///         Recovering --> [*]: still no ack (replay, balance releases, reopen)
///     }
///     Open --> Transaction: closing colon / confirm / click
///     Transaction --> Open
/// ```
///
/// Invariants:
/// - Text is decoded only in `Open`, never during secure input, and never
///   with Command, Control or Option held. Anything that may move focus
///   closes the gate before it is passed to the host.
/// - Capture opens only while focused-element tracking is active for the
///   frontmost app, so a programmatic focus change is always noticed.
/// - A swallowed key press is owned until its release: repeats and the
///   key-up are swallowed regardless of what else is going on.
/// - During a transaction physical keys are held, then fed through this same
///   logic exactly once when drained, and only those that pass are replayed
///   to the host, after the replacement's own events.
/// - Nothing is posted unless `commit` succeeds at execution time: the
///   transaction is current, verified, uncancelled, on the same focus
///   generation, the gate is open, and secure input is off.
public struct InputGate: Sendable {
    public enum KeyDecision: Equatable, Sendable {
        case pass
        case swallow
        case hold
    }

    public struct KeyResult: Equatable, Sendable {
        public let decision: KeyDecision
        public let effects: [GateEffect]
    }

    // MARK: State

    private enum Capture: Equatable {
        case closed
        case open(anchor: CGRect, target: FocusTarget)
    }

    private struct Session: Equatable {
        let tokenID: Int
        /// Focus as confirmed by this token's probe; nil until it answers.
        var focus: (anchor: CGRect, target: FocusTarget)?
        let isExcluded: Bool

        static func == (lhs: Session, rhs: Session) -> Bool {
            lhs.tokenID == rhs.tokenID && lhs.isExcluded == rhs.isExcluded
                && lhs.focus?.anchor == rhs.focus?.anchor && lhs.focus?.target == rhs.focus?.target
        }
    }

    private struct HeldEvent: Equatable {
        let event: KeyEvent
        /// Text decoded when the event arrived, if decoding was allowed then.
        let text: String?
    }

    private enum Phase: Equatable {
        /// Waiting for `verifyResult`; nothing posted yet.
        case verifying
        /// Verified; the replacement is queued but not yet committed.
        case authorized
        /// Deletes, text and a flush are posted; waiting for `flushAck`.
        case posting
        /// Held keys replayed and another flush posted; waiting for `flushAck`.
        case draining
        /// Acknowledgements stopped coming; held keys were replayed and a
        /// flush posted to find out whether the stream is alive.
        case recovering

        var isBeforeCommit: Bool { self == .verifying || self == .authorized }
    }

    private struct Transaction: Equatable {
        let id: Int
        let typed: String
        let target: FocusTarget
        let focusGeneration: Int
        var phase: Phase
        var held: [HeldEvent] = []
        /// Keys whose press is held, so their release is held too (in order).
        var heldDownKeys: Set<UInt16> = []
        /// Presses replayed to the host during recovery whose release has not
        /// been seen; balanced with synthetic releases if recovery gives up.
        var replayedDownKeys: Set<UInt16> = []
        /// Set once the replacement was carried out.
        var inserted: String?
        var cancelled = false
        var missedAcks = 0
    }

    /// A `:shortcode:` completed by drained keys while a transaction was still
    /// running; started once that transaction ends.
    private struct DeferredCompletion: Equatable {
        let shortcode: String
        let typed: String
    }

    public let minimumQueryLength: Int
    /// How many missing acknowledgements recovery tolerates before giving up.
    public static let recoveryAttempts = 2

    private var machine = TriggerMachine()
    private var session: Session?
    private var capture = Capture.closed
    private var focusGeneration = 0
    private var trackingActive = false
    private var frontmostExcluded = false
    private var transaction: Transaction?
    private var deferred: DeferredCompletion?
    private var nextTransactionID = 0
    private var ownedKeys: Set<UInt16> = []
    public private(set) var isPickerVisible = false

    public init(minimumQueryLength: Int = 2) {
        self.minimumQueryLength = minimumQueryLength
    }

    // MARK: Introspection

    public var token: TriggerMachine.Token? { machine.current.token }

    /// Typed characters may be decoded and buffered.
    public var capturesText: Bool {
        if case .open = capture { return true }
        return false
    }

    public var isHolding: Bool { transaction != nil }

    public var currentFocusGeneration: Int { focusGeneration }

    // MARK: Keyboard

    /// - Parameter text: decodes the typed characters; called only when the
    ///   gate is open, secure input is off and no chord modifier is held.
    public mutating func key(_ event: KeyEvent, text: () -> String) -> KeyResult {
        if let owned = ownershipDecision(event) { return owned }

        let mayDecode = capturesText && !event.secureInput && !Self.isChord(event.modifiers) && event.isDown
        let decoded = mayDecode ? text() : nil

        if var current = transaction {
            // Physical keys are held for the whole transaction, including the
            // drain, so nothing overtakes the replacement or its replay. A
            // release whose press already reached the host passes straight
            // through; it cannot reorder text.
            if !event.isDown && !current.heldDownKeys.contains(event.keyCode) {
                if current.replayedDownKeys.remove(event.keyCode) != nil { transaction = current }
                return KeyResult(decision: .pass, effects: [])
            }
            if event.isDown { current.heldDownKeys.insert(event.keyCode) } else { current.heldDownKeys.remove(event.keyCode) }
            current.held.append(HeldEvent(event: event, text: decoded))
            transaction = current
            var effects: [GateEffect] = []
            if event.secureInput, current.phase.isBeforeCommit {
                effects += cancelTransaction()
            }
            return KeyResult(decision: .hold, effects: effects)
        }
        return process(event, text: decoded)
    }

    /// Ownership comes before everything else: a swallowed press stays ours
    /// until it is released, whatever else is going on.
    private mutating func ownershipDecision(_ event: KeyEvent) -> KeyResult? {
        if !event.isDown {
            return ownedKeys.remove(event.keyCode) != nil ? KeyResult(decision: .swallow, effects: []) : nil
        }
        guard ownedKeys.contains(event.keyCode) else { return nil }
        // A repeat of a swallowed press: keep it away from the host, and let
        // the picker use it while it is open.
        guard isPickerVisible, transaction == nil else { return KeyResult(decision: .swallow, effects: []) }
        let input = Self.classify(event, text: "")
        return KeyResult(decision: .swallow, effects: input.isPickerCommand ? handlePickerCommand(input, keyCode: event.keyCode) : [])
    }

    /// Runs one event through classification and the trigger logic. For live
    /// events the decision goes back to the tap; for drained events a `.pass`
    /// decision becomes a replay.
    private mutating func process(_ event: KeyEvent, text: String?) -> KeyResult {
        guard event.isDown else { return KeyResult(decision: .pass, effects: []) }

        if event.secureInput {
            return KeyResult(decision: .pass, effects: forgetTyping())
        }
        let input = Self.classify(event, text: text ?? "")
        switch input {
        case .text(let string):
            guard capturesText else { return KeyResult(decision: .pass, effects: []) }
            return KeyResult(decision: .pass, effects: apply(machine.handle(.text(string))))
        case .backspace:
            guard capturesText else { return KeyResult(decision: .pass, effects: []) }
            return KeyResult(decision: .pass, effects: apply(machine.handle(.backspace)))
        case .ignore:
            return KeyResult(decision: .pass, effects: [])
        case .reset:
            // Arrows and the like move the caret, not focus.
            return KeyResult(decision: .pass, effects: forgetTyping())
        case .focusMoving:
            return KeyResult(decision: .pass, effects: closeGate())
        case .movePrevious, .moveNext, .escape:
            if isPickerVisible {
                ownedKeys.insert(event.keyCode)
                return KeyResult(decision: .swallow, effects: handlePickerCommand(input, keyCode: event.keyCode))
            }
            return KeyResult(decision: .pass, effects: forgetTyping())
        case .confirm:
            if isPickerVisible {
                ownedKeys.insert(event.keyCode)
                return KeyResult(decision: .swallow, effects: handlePickerCommand(input, keyCode: event.keyCode))
            }
            // Return or Tab reaching the host may submit a form or move focus.
            return KeyResult(decision: .pass, effects: closeGate())
        }
    }

    private mutating func handlePickerCommand(_ input: KeyInput, keyCode: UInt16) -> [GateEffect] {
        switch input {
        case .movePrevious: return [.moveSelection(by: -1)]
        case .moveNext: return [.moveSelection(by: 1)]
        case .escape: return apply(machine.handle(.dismiss))
        case .confirm: return confirmSelection(fallbackKeyCode: keyCode)
        default: return []
        }
    }

    private mutating func confirmSelection(fallbackKeyCode: UInt16?) -> [GateEffect] {
        guard let token = machine.current.token, let session, session.tokenID == token.id,
              let focus = session.focus, !session.isExcluded, transaction == nil
        else {
            var effects: [GateEffect] = []
            if let fallbackKeyCode { effects.append(.repost(keyCode: fallbackKeyCode)) }
            return effects + forgetTyping()
        }
        return beginTransaction(source: .selection, typed: token.typed, target: focus.target)
    }

    // MARK: Mouse, focus, picker

    /// A mouse button went down. Clicks inside the picker are its own.
    public mutating func mouseDown(onPicker: Bool) -> [GateEffect] {
        guard !onPicker else { return [] }
        return closeGate()
    }

    /// A picker row was clicked (the app layer selected it first).
    public mutating func pickerClicked() -> [GateEffect] {
        guard isPickerVisible else { return [] }
        return confirmSelection(fallbackKeyCode: nil)
    }

    /// Focus may have moved (app activation, Accessibility notification).
    /// Capture closes immediately; a probe reopens it if the field is editable.
    public mutating func focusMayHaveMoved() -> [GateEffect] {
        closeGate()
    }

    /// Whether focused-element notifications are being received for the
    /// frontmost app. Capture needs them; without them a programmatic focus
    /// change (say, a login form advancing to its password field) would go
    /// unnoticed. Becoming active asks for a fresh probe.
    public mutating func focusTracking(active: Bool) -> [GateEffect] {
        guard trackingActive != active else { return [] }
        trackingActive = active
        if active {
            return [.requestProbe(generation: focusGeneration, tokenID: nil)]
        }
        return closeGate()
    }

    /// Whether the frontmost app is on the exclusion list. Computed by the
    /// app layer whenever the frontmost app or the list changes.
    public mutating func frontmostApp(excluded: Bool) {
        frontmostExcluded = excluded
    }

    /// Answer to `.requestProbe`.
    public mutating func probeResult(generation: Int, tokenID: Int?, _ result: FocusResult) -> [GateEffect] {
        guard generation == focusGeneration else { return [] }
        switch result {
        case .editable(let anchor, let target) where trackingActive:
            capture = .open(anchor: anchor, target: target)
            if let tokenID, var current = session, current.tokenID == tokenID {
                current.focus = (anchor, target)
                session = current
            }
            return refreshPicker()
        case .editable, .secure, .unavailable:
            capture = .closed
            var effects = forgetTyping()
            if let transaction, transaction.phase.isBeforeCommit { effects += cancelTransaction() }
            return effects
        }
    }

    public mutating func pickerVisibility(_ visible: Bool) {
        isPickerVisible = visible
    }

    // MARK: Transactions

    /// Answer to `.beginInsertion`. Authorizes posting; the actual posting is
    /// decided by `commit` when the queued work runs.
    public mutating func verifyResult(transaction id: Int, _ result: VerifyResult) -> [GateEffect] {
        guard var current = transaction, current.id == id, current.phase == .verifying else { return [] }
        switch result {
        case .keystrokes(let text) where isAuthorized(current):
            current.phase = .authorized
            current.inserted = text
            transaction = current
            return [.post(transaction: id, deleteCount: current.typed.count, text: text), .armWatchdog(transaction: id)]
        default:
            return cancelTransaction()
        }
    }

    /// Called by the app layer at the moment the queued replacement is about
    /// to be posted. Returns true only if every condition still holds; then
    /// the transaction is in `posting` and the caller must post the events
    /// and the flush at once. Returns false with cancel effects otherwise.
    public mutating func commit(transaction id: Int, secureInput: Bool) -> (proceed: Bool, effects: [GateEffect]) {
        guard var current = transaction, current.id == id, current.phase == .authorized else {
            return (false, [])
        }
        guard !secureInput, isAuthorized(current) else {
            return (false, cancelTransaction())
        }
        current.phase = .posting
        transaction = current
        return (true, [])
    }

    private func isAuthorized(_ transaction: Transaction) -> Bool {
        !transaction.cancelled && transaction.focusGeneration == focusGeneration && capturesText && trackingActive
    }

    /// The flush marker for `id` came back through the tap: everything posted
    /// before it has reached the host. Drain held keys, then replay them.
    public mutating func flushAck(transaction id: Int) -> [GateEffect] {
        guard var current = transaction, current.id == id, !current.phase.isBeforeCommit else { return [] }
        if current.phase == .posting {
            // Our deletes and text have reached the host; update history
            // before any drained key is appended after them.
            if let inserted = current.inserted {
                machine.handle(.replaced(count: current.typed.count, with: inserted))
            }
        }
        current.phase = .draining
        current.missedAcks = 0
        current.replayedDownKeys.removeAll()
        transaction = current
        // Keys held after a drained shortcode completion belong to the next
        // transaction; nothing else is drained here.
        guard deferred == nil, !current.held.isEmpty else {
            return finishTransaction()
        }
        let held = current.held
        current.held = []
        current.heldDownKeys = []
        transaction = current
        // Feed held keys through the same logic, once, in order. Keys that
        // pass are replayed. If a drained key completes a shortcode, the
        // keys after it wait for the next transaction so they land after
        // that replacement too.
        var effects: [GateEffect] = []
        var replay: [Int] = []
        var dropped: [Int] = []
        for (index, entry) in held.enumerated() {
            let result = ownershipDecision(entry.event) ?? process(entry.event, text: entry.text)
            effects += result.effects
            switch result.decision {
            case .pass: replay.append(entry.event.id)
            case .swallow, .hold: dropped.append(entry.event.id)
            }
            if deferred != nil, var current = transaction {
                let rest = Array(held[(index + 1)...])
                current.held = rest
                current.heldDownKeys = Set(rest.filter(\.event.isDown).map(\.event.keyCode))
                transaction = current
                break
            }
        }
        if !replay.isEmpty { effects.append(.replay(eventIDs: replay)) }
        if !dropped.isEmpty { effects.append(.drop(eventIDs: dropped)) }
        effects += [.postFlush(transaction: id), .armWatchdog(transaction: id)]
        return effects
    }

    /// The watchdog for `id` fired: an acknowledgement did not arrive in time.
    public mutating func timeout(transaction id: Int) -> [GateEffect] {
        guard var current = transaction, current.id == id else { return [] }
        switch current.phase {
        case .verifying, .authorized:
            // Verification or the queue is slow: nothing may be posted any more.
            return cancelTransaction()
        case .posting, .draining:
            current.missedAcks += 1
            if current.missedAcks == 1 {
                // One more chance for the flush; meanwhile nothing else is posted.
                transaction = current
                return [.postFlush(transaction: id), .armWatchdog(transaction: id)]
            }
            transaction = current
            return recover()
        case .recovering:
            current.missedAcks += 1
            transaction = current
            return current.missedAcks > Self.recoveryAttempts ? giveUp() : recover()
        }
    }

    /// The tap was disabled by the system and re-enabled: events may have
    /// been lost, including a flush marker, but the stream is alive.
    public mutating func tapInterrupted() -> [GateEffect] {
        ownedKeys.removeAll()
        var effects: [GateEffect] = []
        if let current = transaction {
            effects += current.phase.isBeforeCommit ? cancelTransaction() : recover()
        }
        return effects + closeGate()
    }

    /// The tap is gone (stopped or the app paused): no event will flow until
    /// it starts again, so ordering is moot; deliver what is owed and reset.
    public mutating func tapStopped() -> [GateEffect] {
        ownedKeys.removeAll()
        var effects: [GateEffect] = []
        if transaction != nil { effects += giveUp() }
        return effects + closeGate()
    }

    // MARK: Internals

    private mutating func beginTransaction(
        source: InsertionSource, typed: String, target: FocusTarget, carrying held: [HeldEvent] = []
    ) -> [GateEffect] {
        nextTransactionID += 1
        let id = nextTransactionID
        var next = Transaction(id: id, typed: typed, target: target, focusGeneration: focusGeneration, phase: .verifying)
        next.held = held
        next.heldDownKeys = Set(held.filter(\.event.isDown).map(\.event.keyCode)).subtracting(held.filter { !$0.event.isDown }.map(\.event.keyCode))
        transaction = next
        session = nil
        return [
            .dismissPicker,
            .beginInsertion(transaction: id, source: source, typed: typed, target: target),
            .armWatchdog(transaction: id),
        ]
    }

    /// Stops a transaction before anything was posted and drains its held keys.
    private mutating func cancelTransaction() -> [GateEffect] {
        guard var current = transaction, current.phase.isBeforeCommit else { return [] }
        current.cancelled = true
        current.inserted = nil
        current.phase = .draining
        transaction = current
        _ = machine.handle(.reset)
        session = nil
        // Nothing of ours is in flight, so the flush comes straight back and
        // the drain replays the held keys in order.
        return [.dismissPicker, .postFlush(transaction: current.id), .armWatchdog(transaction: current.id)]
    }

    /// Transaction over: count the replacement, reopen, and resume anything
    /// the drain left pending (a visible picker, a completed shortcode).
    private mutating func finishTransaction() -> [GateEffect] {
        guard let current = transaction else { return [] }
        transaction = nil
        var effects: [GateEffect] = [
            .transactionEnded(transaction: current.id, recordUse: current.inserted != nil && !current.cancelled),
        ]
        if let completion = deferred {
            deferred = nil
            let excluded = session?.isExcluded ?? true
            session = nil
            if case .open(_, let target) = capture, !excluded {
                return effects + beginTransaction(
                    source: .shortcode(completion.shortcode), typed: completion.typed, target: target, carrying: current.held
                )
            }
            // Cannot insert after all: let the keys that waited through.
            let ids = current.held.map(\.event.id)
            if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
            machine.handle(.reset)
            return effects + [.dismissPicker]
        }
        effects += refreshPicker()
        return effects
    }

    /// Acknowledgements stopped: replay what is held now, keep holding, and
    /// post another flush to see whether the stream is alive. Presses replayed
    /// this way are remembered so their releases can be balanced.
    private mutating func recover() -> [GateEffect] {
        guard var current = transaction else { return [] }
        current.phase = .recovering
        let ids = current.held.map(\.event.id)
        for entry in current.held {
            if entry.event.isDown { current.replayedDownKeys.insert(entry.event.keyCode) } else { current.replayedDownKeys.remove(entry.event.keyCode) }
        }
        current.held = []
        current.heldDownKeys = []
        transaction = current
        var effects: [GateEffect] = []
        if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
        return effects + [.postFlush(transaction: current.id), .armWatchdog(transaction: current.id)]
    }

    /// The stream is not answering. Deliver everything owed in order, release
    /// any press whose release may already have passed, and forget typing.
    private mutating func giveUp() -> [GateEffect] {
        guard var current = transaction else { return [] }
        transaction = nil
        deferred = nil
        let ids = current.held.map(\.event.id)
        for entry in current.held {
            if entry.event.isDown { current.replayedDownKeys.insert(entry.event.keyCode) } else { current.replayedDownKeys.remove(entry.event.keyCode) }
        }
        var effects: [GateEffect] = []
        if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
        if !current.replayedDownKeys.isEmpty { effects.append(.release(keyCodes: current.replayedDownKeys.sorted())) }
        effects.append(.transactionEnded(transaction: current.id, recordUse: false))
        return effects + forgetTyping()
    }

    private mutating func forgetTyping() -> [GateEffect] {
        machine.handle(.reset)
        session = nil
        deferred = nil
        return [.dismissPicker]
    }

    /// Closes capture and asks for a fresh probe of the focused element.
    private mutating func closeGate() -> [GateEffect] {
        var effects = forgetTyping()
        capture = .closed
        focusGeneration += 1
        if let transaction, transaction.phase.isBeforeCommit {
            effects += cancelTransaction()
        }
        if trackingActive {
            effects.append(.requestProbe(generation: focusGeneration, tokenID: nil))
        }
        return effects
    }

    private mutating func apply(_ output: TriggerMachine.Output) -> [GateEffect] {
        if let shortcode = output.completedShortcode, let typed = output.completedText {
            guard let session, !session.isExcluded else {
                self.session = nil
                return [.dismissPicker]
            }
            if transaction != nil {
                // Completed by a drained key: start after the current one ends.
                deferred = DeferredCompletion(shortcode: shortcode, typed: typed)
                return []
            }
            guard let focus = session.focus else {
                self.session = nil
                return [.dismissPicker]
            }
            return beginTransaction(source: .shortcode(shortcode), typed: typed, target: focus.target)
        }
        guard let token = output.token, !token.isDismissed else {
            session = nil
            return [.dismissPicker]
        }
        var effects: [GateEffect] = []
        if session?.tokenID != token.id {
            session = Session(tokenID: token.id, focus: nil, isExcluded: frontmostExcluded)
            if !frontmostExcluded {
                // Re-check the element at the colon: focus may have moved
                // without notice, and the caret position is needed anyway.
                effects.append(.requestProbe(generation: focusGeneration, tokenID: token.id))
            }
        }
        return effects + refreshPicker()
    }

    private func refreshPicker() -> [GateEffect] {
        guard let session, !session.isExcluded, let focus = session.focus,
              let token = machine.current.token, token.id == session.tokenID, !token.isDismissed,
              token.query.count >= minimumQueryLength, transaction == nil
        else {
            return [.dismissPicker]
        }
        return [.presentPicker(query: token.query, anchor: focus.anchor)]
    }

    // MARK: Classification

    /// Command, Control and Option chords belong to the host and may move
    /// focus. Shift is part of ordinary typing (`:` is Shift-semicolon).
    static func isChord(_ modifiers: KeyModifiers) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    static func classify(_ event: KeyEvent, text: String) -> KeyInput {
        if isChord(event.modifiers) {
            return .focusMoving
        }
        let shift = event.modifiers.contains(.shift)
        switch event.keyCode {
        case KeyCode.delete:
            return .backspace
        case KeyCode.upArrow, KeyCode.leftArrow:
            return shift ? .reset : .movePrevious
        case KeyCode.downArrow, KeyCode.rightArrow:
            return shift ? .reset : .moveNext
        case KeyCode.return, KeyCode.keypadEnter, KeyCode.tab:
            return shift ? .focusMoving : .confirm
        case KeyCode.escape:
            return shift ? .reset : .escape
        case KeyCode.forwardDelete, KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown, KeyCode.help:
            return .reset
        default:
            guard !text.isEmpty else { return .ignore }
            let isControlOrFunctionKey = text.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
            }
            return isControlOrFunctionKey ? .reset : .text(text)
        }
    }
}

/// What a keyboard event means to OpenReaction.
public enum KeyInput: Equatable, Sendable {
    case text(String)
    case backspace
    /// The caret moved within the field (arrows with Shift, Home, End, …).
    case reset
    /// The key may move focus to another field or app (chords, Shift-Tab).
    case focusMoving
    /// ← or ↑.
    case movePrevious
    /// → or ↓.
    case moveNext
    /// Return, keypad Enter or Tab.
    case confirm
    case escape
    /// A key that neither types nor moves the caret (e.g. a dead-key prefix).
    case ignore

    /// Keys the picker consumes while it is visible.
    public var isPickerCommand: Bool {
        switch self {
        case .movePrevious, .moveNext, .confirm, .escape: true
        default: false
        }
    }
}
