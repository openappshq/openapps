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
    /// Query the focused element and call `probeResult` with these ids. A
    /// non-nil `tokenID` is a token probe: keys are being held until it answers.
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
    /// Call `replayExecuted` once every replay posted before this point has
    /// actually been posted (the insertion queue ran it). Used only when the
    /// stream can no longer acknowledge, during a shutdown.
    case confirmReplay(transaction: Int)
    /// Before a delayed (best-effort) replay: look up the focused element
    /// and call `destinationChecked` with whether it is still `target`.
    /// Held input is never replayed anywhere else.
    case checkDestination(transaction: Int, target: FocusTarget)
    /// Held input was dropped because its destination changed: tell the user
    /// that some typing could not be restored.
    case inputLost(eventCount: Int)
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

public enum MouseEventKind: Equatable, Sendable {
    case down
    case up
    case drag
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
///     [*] --> Idle
///     Idle --> Idle: keys pass; only "last char was a word char" is kept
///     Idle --> Probing: boundary colon (colon and following keys held)
///     Probing --> Idle: probe not editable / stale / cancelled → replay untouched
///     Probing --> InToken: probe editable → held keys interpreted, replayed, flushed
///     InToken --> Idle: token ends (space, Esc, backspace over colon)
///     InToken --> Verifying: closing colon / confirm / click (keys held)
///     Verifying --> Authorized: verifyResult keystrokes
///     Authorized --> Posting: commit succeeds at execution time (mouse now held too)
///     Verifying --> Draining: refused · cancel
///     Authorized --> Draining: cancel · commit refused
///     Posting --> Draining: flushAck
///     Draining --> Draining: flushAck with newly held events → drain, replay, re-flush
///     Draining --> Idle: flushAck, nothing held → deferred colon or shortcode starts next
///     Posting --> Recovering: second missed ack / tap re-enabled → replay held, flush
///     Recovering --> Draining: flushAck
///     Recovering --> Idle: still no ack → replay owed in order, forget
/// ```
///
/// Invariants:
/// - Outside a token nothing typed is retained: only one bit, whether the
///   previous character was part of a word (for the colon boundary rule).
/// - A colon is interpreted only after a fresh probe of the focused element,
///   for the current focus generation, says editable and tracked. Until then
///   the colon and everything after it are held undecoded; if the probe says
///   otherwise they are replayed untouched.
/// - Text is decoded only in a validated token or for the colon/boundary
///   check, never during secure input, never with a chord modifier held.
/// - A swallowed key press is owned until its release. A held press keeps
///   its release held until the flush after its replay is acknowledged.
/// - Nothing is posted unless `commit` succeeds at execution time; from then
///   until the flush is acknowledged, mouse events are held as well.
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

    /// How a shutdown ended. Only `.delivered` means the tap acknowledged
    /// everything the gate owed the host.
    public enum ShutdownOutcome: Equatable, Sendable {
        /// Every held or replayed event was acknowledged by the tap.
        case delivered
        /// macOS disabled the tap meanwhile; what was owed was replayed and
        /// the replay ran, but no acknowledgement confirms its arrival.
        case interrupted
        /// A flush could not be posted, or no acknowledgement came within the
        /// app layer's bound; what was owed was replayed in order and the
        /// replay ran, unacknowledged.
        case failed
    }

    // MARK: State

    private enum Capture: Equatable {
        case closed
        case open(anchor: CGRect, target: FocusTarget)
    }

    private struct Session: Equatable {
        let tokenID: Int
        let anchor: CGRect
        let target: FocusTarget
    }

    private enum HeldEvent: Equatable {
        case key(KeyEvent)
        case mouse(id: Int, kind: MouseEventKind)

        var id: Int {
            switch self {
            case .key(let event): event.id
            case .mouse(let id, _): id
            }
        }
    }

    private enum Phase: Equatable {
        /// A colon was typed; waiting for the token probe. Nothing decoded yet.
        case probing
        /// Waiting for `verifyResult`; nothing posted yet.
        case verifying
        /// Verified; the replacement is queued but not yet committed.
        case authorized
        /// Deletes, text and a flush are posted; waiting for `flushAck`.
        case posting
        /// Held events replayed and another flush posted; waiting for `flushAck`.
        case draining
        /// Acknowledgements stopped coming; held events were replayed and a
        /// flush posted to find out whether the stream is alive.
        case recovering
        /// Shutting down and the stream cannot acknowledge any more (the tap
        /// was interrupted, or a flush could not be posted): held events were
        /// replayed and the gate waits for the app layer to confirm that the
        /// replay was executed, holding new input behind it meanwhile.
        case bestEffort

        var isBeforeCommit: Bool { self == .probing || self == .verifying || self == .authorized }
        var holdsMouse: Bool { self == .posting || self == .draining || self == .recovering || self == .bestEffort }
    }

    private enum Kind: Equatable {
        case tokenStart(tokenID: Int)
        case replacement(typed: String, target: FocusTarget)
    }

    private struct Transaction: Equatable {
        let id: Int
        let kind: Kind
        let focusGeneration: Int
        var phase: Phase
        var held: [HeldEvent] = []
        /// Presses in `held` (chronologically), so their releases are held too.
        var heldDownKeys: Set<UInt16> = []
        /// Presses replayed but not yet acknowledged; their releases stay held.
        var replayingDownKeys: Set<UInt16> = []
        /// Set once the replacement was carried out.
        var inserted: String?
        var cancelled = false
        var missedAcks = 0
        /// How the shutdown ends if this transaction is its last: set when
        /// the stream stopped acknowledging.
        var bestEffortOutcome: ShutdownOutcome?
        /// Where the held input was typed; a delayed replay goes nowhere else.
        var origin: FocusTarget?
        /// A `checkDestination` is out; held input waits for its answer.
        var awaitingDestination = false

        /// Appends an event, tracking presses chronologically so their
        /// releases are held too (a release then a new press counts again).
        mutating func hold(_ event: HeldEvent) {
            held.append(event)
            if case .key(let key) = event {
                if key.isDown { heldDownKeys.insert(key.keyCode) } else { heldDownKeys.remove(key.keyCode) }
            }
        }

        mutating func recomputeHeldDownKeys() {
            heldDownKeys = []
            for event in held {
                if case .key(let key) = event {
                    if key.isDown { heldDownKeys.insert(key.keyCode) } else { heldDownKeys.remove(key.keyCode) }
                }
            }
        }
    }

    /// Something a drained key started that must wait for the current
    /// transaction to end, so replay order is preserved.
    private enum Deferred: Equatable {
        case tokenStart
        case completion(shortcode: String, typed: String)
    }

    public let minimumQueryLength: Int
    /// How many missing acknowledgements recovery tolerates before giving up.
    public static let recoveryAttempts = 2

    private var machine = TriggerMachine()
    private var session: Session?
    /// Outside a token: whether a colon here would follow a word boundary.
    private var atBoundary = true
    private var capture = Capture.closed
    private var focusGeneration = 0
    private var trackingActive = false
    private var frontmostExcluded = false
    private var transaction: Transaction?
    private var deferred: Deferred?
    private var nextTransactionID = 0
    private var nextTokenID = 0
    private var ownedKeys: Set<UInt16> = []
    public private(set) var isPickerVisible = false

    public init(minimumQueryLength: Int = 2) {
        self.minimumQueryLength = minimumQueryLength
    }

    // MARK: Introspection

    public var token: TriggerMachine.Token? { session == nil ? nil : machine.current.token }

    /// A validated field has focus, so a colon may start a token.
    public var capturesText: Bool {
        if case .open = capture { return true }
        return false
    }

    public var isHolding: Bool { transaction != nil }

    /// The transaction currently holding input, if any.
    public var currentTransactionID: Int? { transaction?.id }

    public var currentFocusGeneration: Int { focusGeneration }

    // MARK: Keyboard

    /// - Parameter text: decodes the typed characters; called only for a key
    ///   pressed in a validated field with no chord modifier and secure input
    ///   off. Outside a token the result is used for one check and dropped.
    public mutating func key(_ event: KeyEvent, text: () -> String) -> KeyResult {
        if let owned = ownershipDecision(event) { return owned }

        if var current = transaction {
            // Everything physical is held for the whole transaction so nothing
            // overtakes the replacement or its replay. A release passes only
            // if its press already reached the host.
            if !event.isDown,
               !current.heldDownKeys.contains(event.keyCode), !current.replayingDownKeys.contains(event.keyCode) {
                return KeyResult(decision: .pass, effects: [])
            }
            current.hold(.key(event))
            transaction = current
            var effects: [GateEffect] = []
            if event.secureInput, current.phase.isBeforeCommit {
                effects += cancelTransaction()
            }
            return KeyResult(decision: .hold, effects: effects)
        }
        return process(event, text: text)
    }

    /// Ownership comes before everything else: a swallowed press stays ours
    /// until it is released, whatever else is going on.
    private mutating func ownershipDecision(_ event: KeyEvent) -> KeyResult? {
        if !event.isDown {
            return ownedKeys.remove(event.keyCode) != nil ? KeyResult(decision: .swallow, effects: []) : nil
        }
        guard ownedKeys.contains(event.keyCode) else { return nil }
        guard isPickerVisible, transaction == nil else { return KeyResult(decision: .swallow, effects: []) }
        let input = Self.classify(event, text: { "" })
        return KeyResult(decision: .swallow, effects: input.isPickerCommand ? handlePickerCommand(input, keyCode: event.keyCode) : [])
    }

    /// Runs one live or drained event through classification and the trigger
    /// logic. `.pass` for a drained event means replay.
    private mutating func process(_ event: KeyEvent, text: () -> String) -> KeyResult {
        guard event.isDown else { return KeyResult(decision: .pass, effects: []) }
        if event.secureInput {
            return KeyResult(decision: .pass, effects: forgetTyping())
        }
        let mayDecode = capturesText && !Self.isChord(event.modifiers)
        let input = Self.classify(event, text: mayDecode ? text : { "" })
        switch input {
        case .text(let string):
            let wasHolding = transaction != nil
            let wasDeferred = deferred != nil
            let effects = typed(string)
            if !wasHolding, var started = transaction, case .tokenStart = started.kind {
                // A boundary colon: hold it (and what follows) until the probe answers.
                started.hold(.key(event))
                transaction = started
                return KeyResult(decision: .hold, effects: effects)
            }
            if !wasDeferred, deferred == .tokenStart {
                // A drained colon: it waits, with everything after it, for its own probe.
                return KeyResult(decision: .hold, effects: effects)
            }
            return KeyResult(decision: .pass, effects: effects)
        case .backspace:
            if session != nil {
                return KeyResult(decision: .pass, effects: apply(machine.handle(.backspace)))
            }
            atBoundary = false
            return KeyResult(decision: .pass, effects: [])
        case .ignore:
            return KeyResult(decision: .pass, effects: [])
        case .reset:
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
            return KeyResult(decision: .pass, effects: closeGate())
        }
    }

    /// A printable character in a validated field.
    private mutating func typed(_ string: String) -> [GateEffect] {
        if session != nil {
            let effects = apply(machine.handle(.text(string)))
            if session == nil, transaction == nil {
                atBoundary = string.last.map(TriggerMachine.isBoundary) ?? true
            }
            return effects
        }
        // Outside a token: is this a colon at a word boundary? Nothing else
        // about the character is kept.
        let startsToken = string == ":" && atBoundary
        atBoundary = string.last.map(TriggerMachine.isBoundary) ?? true
        guard startsToken, !frontmostExcluded else { return [] }
        if transaction != nil {
            // Typed by a drained key: probe once the current transaction ends.
            deferred = .tokenStart
            return []
        }
        return beginTokenStart()
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
        guard let session, let token = machine.current.token, session.tokenID == token.id, transaction == nil else {
            var effects: [GateEffect] = []
            if let fallbackKeyCode { effects.append(.repost(keyCode: fallbackKeyCode)) }
            return effects + forgetTyping()
        }
        return beginReplacement(source: .selection, typed: token.typed, target: session.target)
    }

    // MARK: Mouse, focus, picker

    /// A mouse button event. Clicks inside the picker are its own. After a
    /// replacement is committed, mouse events are held until its flush is
    /// acknowledged so they cannot land between our posted events.
    public mutating func mouse(_ kind: MouseEventKind, id: Int, onPicker: Bool) -> KeyResult {
        if var current = transaction, current.phase.holdsMouse {
            current.hold(.mouse(id: id, kind: kind))
            transaction = current
            return KeyResult(decision: .hold, effects: [])
        }
        guard kind == .down, !onPicker else { return KeyResult(decision: .pass, effects: []) }
        return KeyResult(decision: .pass, effects: closeGate())
    }

    /// A picker row was clicked (the app layer selected it first).
    public mutating func pickerClicked() -> [GateEffect] {
        guard isPickerVisible else { return [] }
        return confirmSelection(fallbackKeyCode: nil)
    }

    /// Focus may have moved (app activation, Accessibility notification).
    public mutating func focusMayHaveMoved() -> [GateEffect] {
        closeGate()
    }

    /// Whether focused-element notifications are being received for the
    /// frontmost app. Without them a programmatic focus change would go
    /// unnoticed, so capture stays closed.
    public mutating func focusTracking(active: Bool) -> [GateEffect] {
        guard !isShuttingDown, trackingActive != active else { return [] }
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

    /// Answer to `.requestProbe`. For a token probe, `decode` returns the
    /// characters of a held key by event id; it is called only when the probe
    /// authorized interpretation.
    public mutating func probeResult(
        generation: Int, tokenID: Int?, _ result: FocusResult, decode: (Int) -> String = { _ in "" }
    ) -> [GateEffect] {
        guard !isShuttingDown, generation == focusGeneration else { return [] }
        switch result {
        case .editable(let anchor, let target) where trackingActive:
            capture = .open(anchor: anchor, target: target)
            guard let tokenID, var current = transaction, current.kind == .tokenStart(tokenID: tokenID), current.phase == .probing else {
                return refreshPicker()
            }
            // The field is safe: interpret the held colon and what followed.
            session = Session(tokenID: tokenID, anchor: anchor, target: target)
            machine.handle(.reset)
            current.phase = .draining
            transaction = current
            return drain(decode: decode)
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
            guard case .replacement(let typed, _) = current.kind else { return cancelTransaction() }
            current.phase = .authorized
            current.inserted = text
            transaction = current
            return [.post(transaction: id, deleteCount: typed.count, text: text), .armWatchdog(transaction: id)]
        default:
            return cancelTransaction()
        }
    }

    /// Called by the app layer at the moment the queued replacement is about
    /// to be posted. Returns true only if every condition still holds; then
    /// the transaction is in `posting`, mouse events are held, and the caller
    /// must post the events and the flush at once.
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
    /// before it, including any replay, has reached the host.
    public mutating func flushAck(transaction id: Int, decode: (Int) -> String = { _ in "" }) -> [GateEffect] {
        guard var current = transaction, current.id == id, !current.phase.isBeforeCommit, current.phase != .bestEffort else { return [] }
        if current.phase == .posting, let inserted = current.inserted, case .replacement(let typed, _) = current.kind {
            // Our deletes and text have reached the host; account for them
            // before any drained key is interpreted after them.
            machine.handle(.replaced(count: typed.count, with: inserted))
            session = nil
            atBoundary = true
        }
        if current.phase == .recovering {
            // Delivered, but what was replayed was never interpreted.
            machine.handle(.reset)
            session = nil
            atBoundary = true
        }
        current.phase = .draining
        current.missedAcks = 0
        current.replayingDownKeys.removeAll()
        transaction = current
        return drain(decode: decode)
    }

    /// Feeds held events through the same logic, once, in order; replays the
    /// ones that pass and flushes again, or finishes if nothing was held.
    private mutating func drain(decode: (Int) -> String) -> [GateEffect] {
        guard var current = transaction else { return [] }
        let id = current.id
        if isShuttingDown { deferred = nil } // nothing new starts; leftovers only go out
        guard deferred == nil, !current.held.isEmpty else {
            return finishTransaction()
        }
        let held = current.held
        current.held = []
        current.heldDownKeys = []
        transaction = current

        var effects: [GateEffect] = []
        var replay: [Int] = []
        var dropped: [Int] = []
        if current.cancelled {
            // Nothing was authorized: everything goes back to the host untouched.
            replay = held.map(\.id)
        }
        for (index, entry) in held.enumerated() where !current.cancelled {
            let result: KeyResult
            switch entry {
            case .key(let event):
                result = ownershipDecision(event) ?? process(event) { decode(event.id) }
            case .mouse(_, let kind):
                result = KeyResult(decision: .pass, effects: kind == .down ? closeGate() : [])
            }
            effects += result.effects
            if deferred != nil, var now = transaction {
                // What this key started must wait for the next transaction. A
                // colon that starts a token waits with it; a closing colon is
                // replayed (the replacement deletes it).
                if result.decision == .pass { replay.append(entry.id) }
                let from = result.decision == .hold ? index : index + 1
                now.held = Array(held[from...])
                now.recomputeHeldDownKeys()
                transaction = now
                break
            }
            switch result.decision {
            case .pass: replay.append(entry.id)
            case .swallow, .hold: dropped.append(entry.id)
            }
        }
        if var now = transaction, now.id == id {
            for entryID in replay {
                if case .key(let event)? = held.first(where: { $0.id == entryID }) {
                    if event.isDown { now.replayingDownKeys.insert(event.keyCode) } else { now.replayingDownKeys.remove(event.keyCode) }
                }
            }
            transaction = now
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
        case .probing, .verifying, .authorized:
            return cancelTransaction()
        case .posting, .draining:
            current.missedAcks += 1
            transaction = current
            if current.missedAcks == 1 {
                return [.postFlush(transaction: id), .armWatchdog(transaction: id)]
            }
            return recover()
        case .recovering:
            current.missedAcks += 1
            transaction = current
            // While shutting down no timer may decide that input was
            // delivered: keep asking the stream until it answers, the
            // system disables the tap, or a flush cannot be posted.
            if isShuttingDown { return recover() }
            return current.missedAcks > Self.recoveryAttempts ? giveUp() : recover()
        case .bestEffort:
            return [] // Nothing to time out: waiting for the destination or the replay to run.
        }
    }

    /// The tap was disabled by the system and re-enabled: events may have
    /// been lost, including a flush marker, but the stream is alive. During a
    /// shutdown the acknowledgement may never come, so what is owed goes out
    /// in order, best effort, and the shutdown ends `.interrupted` once that
    /// replay has actually run.
    public mutating func tapInterrupted() -> [GateEffect] {
        ownedKeys.removeAll()
        if isShuttingDown {
            return bestEffortReplay(outcome: .interrupted)
        }
        var effects: [GateEffect] = []
        if let current = transaction {
            effects += current.phase.isBeforeCommit ? cancelTransaction() : recover()
        }
        return effects + closeGate()
    }

    /// The app layer could not post the flush for `id`: no acknowledgement
    /// will ever come for it. What is owed goes out in order, unacknowledged;
    /// during a shutdown the outcome is `.failed`.
    public mutating func streamFailed(transaction id: Int) -> [GateEffect] {
        guard let current = transaction, current.id == id, !current.phase.isBeforeCommit else { return [] }
        if isShuttingDown {
            return bestEffortReplay(outcome: .failed)
        }
        return giveUp() + closeGate()
    }

    /// The app layer stopped waiting for acknowledgements (its bound passed)
    /// while the tap is still installed: what is owed goes out in order,
    /// unacknowledged, and the shutdown ends `.failed` once that replay ran.
    /// New input keeps being held behind it meanwhile.
    public mutating func acknowledgementAbandoned() -> [GateEffect] {
        guard isShuttingDown else { return [] }
        return bestEffortReplay(outcome: .failed)
    }

    /// The insertion queue has run every replay posted before the matching
    /// `confirmReplay`. Input held meanwhile goes out the same way (after
    /// its own destination check); when nothing is left the shutdown ends
    /// with the recorded outcome.
    public mutating func replayExecuted(transaction id: Int) -> [GateEffect] {
        guard var current = transaction, current.id == id, current.phase == .bestEffort, !current.awaitingDestination else { return [] }
        current.replayingDownKeys = []
        guard current.held.isEmpty else {
            transaction = current
            return requestDestinationCheck()
        }
        transaction = nil
        shutdownOutcome = current.bestEffortOutcome ?? .interrupted
        return [.transactionEnded(transaction: id, recordUse: false)] + forgetTyping()
    }

    /// Answer to `checkDestination`. Held input goes out only into the field
    /// it was typed in; otherwise it is dropped and the user is told.
    public mutating func destinationChecked(transaction id: Int, matches: Bool) -> [GateEffect] {
        guard var current = transaction, current.id == id, current.phase == .bestEffort, current.awaitingDestination else { return [] }
        current.awaitingDestination = false
        var effects: [GateEffect] = []
        if matches {
            let ids = Self.replayAllHeld(&current)
            if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
        } else {
            let ids = current.held.map(\.id)
            current.held = []
            current.heldDownKeys = []
            if !ids.isEmpty { effects += [.drop(eventIDs: ids), .inputLost(eventCount: ids.count)] }
        }
        transaction = current
        return effects + [.confirmReplay(transaction: id)]
    }

    /// Shutting down and the stream cannot acknowledge: replay what is held
    /// — after checking it still goes where it was typed — and wait for the
    /// app layer to confirm that the replay ran. New input keeps being held
    /// behind it.
    private mutating func bestEffortReplay(outcome: ShutdownOutcome) -> [GateEffect] {
        guard var current = transaction else {
            if shutdownOutcome == nil { shutdownOutcome = .delivered }
            return []
        }
        if current.phase == .bestEffort { return [] } // already waiting for the replay to run
        current.phase = .bestEffort
        current.bestEffortOutcome = outcome
        current.replayingDownKeys = []
        transaction = current
        if current.held.isEmpty {
            return [.confirmReplay(transaction: current.id)]
        }
        return requestDestinationCheck()
    }

    /// Asks where the focus is before a delayed replay. Without a known
    /// origin nothing is replayed: the answer counts as "changed".
    private mutating func requestDestinationCheck() -> [GateEffect] {
        guard var current = transaction else { return [] }
        current.awaitingDestination = true
        transaction = current
        guard let origin = current.origin else {
            return destinationChecked(transaction: current.id, matches: false)
        }
        return [.checkDestination(transaction: current.id, target: origin)]
    }

    /// Moves everything held to "replayed, unacknowledged": releases of the
    /// replayed presses stay held until the replay is known to have run.
    private static func replayAllHeld(_ current: inout Transaction) -> [Int] {
        let ids = current.held.map(\.id)
        for entry in current.held {
            if case .key(let event) = entry {
                if event.isDown { current.replayingDownKeys.insert(event.keyCode) } else { current.replayingDownKeys.remove(event.keyCode) }
            }
        }
        current.held = []
        current.heldDownKeys = []
        return ids
    }

    /// A deliberate stop is coming (pause, license lock, relaunch, quit).
    /// Nothing new is authorized from here on: focus tracking and probe
    /// answers are ignored, capture never reopens. Anything owed to the host
    /// keeps draining through the acknowledged flush protocol while the tap
    /// still owns the stream; new input that arrives meanwhile is held behind
    /// it and goes out the same way. The app layer waits for `isHolding` to
    /// become false, then calls `tapStopped` and uninstalls the tap. No timer
    /// ends the wait; only `tapInterrupted` does, best effort.
    public mutating func beginShutdown() -> [GateEffect] {
        isShuttingDown = true
        shutdownOutcome = nil
        trackingActive = false
        deferred = nil
        var effects = forgetTyping()
        capture = .closed
        focusGeneration += 1
        if let transaction, transaction.phase.isBeforeCommit {
            effects += cancelTransaction()
        }
        if transaction == nil { shutdownOutcome = .delivered }
        return effects
    }

    /// The tap is gone (stopped or the app paused) after `beginShutdown`
    /// drained everything, or after the tap was uninstalled without a
    /// shutdown. Anything still held goes out in order as a last resort; a
    /// key still physically down is resolved by its next physical release,
    /// which now passes directly.
    public mutating func tapStopped() -> [GateEffect] {
        ownedKeys.removeAll()
        isShuttingDown = false
        shutdownOutcome = nil
        var effects: [GateEffect] = []
        if transaction != nil { effects += giveUp() }
        return effects + closeGate()
    }

    public private(set) var isShuttingDown = false

    /// Set once a shutdown has nothing left to wait for. `nil` while the gate
    /// still owes the host something (or no shutdown is in progress).
    public private(set) var shutdownOutcome: ShutdownOutcome?

    // MARK: Internals

    private mutating func beginTokenStart(carrying held: [HeldEvent] = []) -> [GateEffect] {
        nextTransactionID += 1
        nextTokenID += 1
        var next = Transaction(id: nextTransactionID, kind: .tokenStart(tokenID: nextTokenID), focusGeneration: focusGeneration, phase: .probing)
        next.held = held
        next.recomputeHeldDownKeys()
        if case .open(_, let target) = capture { next.origin = target }
        transaction = next
        return [.requestProbe(generation: focusGeneration, tokenID: nextTokenID), .armWatchdog(transaction: nextTransactionID)]
    }

    private mutating func beginReplacement(
        source: InsertionSource, typed: String, target: FocusTarget, carrying held: [HeldEvent] = []
    ) -> [GateEffect] {
        nextTransactionID += 1
        let id = nextTransactionID
        var next = Transaction(id: id, kind: .replacement(typed: typed, target: target), focusGeneration: focusGeneration, phase: .verifying)
        next.held = held
        next.recomputeHeldDownKeys()
        next.origin = target
        transaction = next
        session = nil
        return [
            .dismissPicker,
            .beginInsertion(transaction: id, source: source, typed: typed, target: target),
            .armWatchdog(transaction: id),
        ]
    }

    /// Stops a transaction before anything was posted: the held keys are
    /// replayed untouched once the flush comes back.
    private mutating func cancelTransaction() -> [GateEffect] {
        guard var current = transaction, current.phase.isBeforeCommit else { return [] }
        current.cancelled = true
        current.inserted = nil
        current.phase = .draining
        transaction = current
        machine.handle(.reset)
        session = nil
        return [.dismissPicker, .postFlush(transaction: current.id), .armWatchdog(transaction: current.id)]
    }

    /// Transaction over: count the replacement and resume whatever a drained
    /// key started (a colon, a completed shortcode, a visible picker).
    private mutating func finishTransaction() -> [GateEffect] {
        guard let current = transaction else { return [] }
        transaction = nil
        var effects: [GateEffect] = [
            .transactionEnded(transaction: current.id, recordUse: current.inserted != nil && !current.cancelled),
        ]
        if current.cancelled, case .tokenStart = current.kind {
            atBoundary = false
        }
        if isShuttingDown {
            // Reached only through an acknowledged flush with nothing held:
            // everything owed has arrived.
            shutdownOutcome = .delivered
            return effects + forgetTyping()
        }
        switch deferred {
        case .tokenStart?:
            deferred = nil
            if capturesText, !frontmostExcluded {
                return effects + beginTokenStart(carrying: current.held)
            }
        case .completion(let shortcode, let typed)?:
            deferred = nil
            if let session {
                return effects + beginReplacement(source: .shortcode(shortcode), typed: typed, target: session.target, carrying: current.held)
            }
        case nil:
            effects += refreshPicker()
            return effects
        }
        // Cannot continue: let the keys that waited through, uninterpreted.
        let ids = current.held.map(\.id)
        if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
        return effects + forgetTyping()
    }

    /// Acknowledgements stopped: replay what is held now, keep holding, and
    /// post another flush to see whether the stream is alive.
    private mutating func recover() -> [GateEffect] {
        guard var current = transaction else { return [] }
        current.phase = .recovering
        let ids = Self.replayAllHeld(&current)
        transaction = current
        var effects: [GateEffect] = []
        if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
        return effects + [.postFlush(transaction: current.id), .armWatchdog(transaction: current.id)]
    }

    /// The stream is not answering. Deliver everything owed in order and
    /// forget typing; nothing is known about the host any more.
    private mutating func giveUp() -> [GateEffect] {
        guard let current = transaction else { return [] }
        transaction = nil
        deferred = nil
        let ids = current.held.map(\.id)
        var effects: [GateEffect] = []
        if !ids.isEmpty { effects.append(.replay(eventIDs: ids)) }
        effects.append(.transactionEnded(transaction: current.id, recordUse: false))
        return effects + forgetTyping()
    }

    /// Leaves any token. Unknown context counts as a boundary.
    private mutating func forgetTyping() -> [GateEffect] {
        machine.handle(.reset)
        session = nil
        deferred = nil
        atBoundary = true
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

    /// Reacts to the trigger machine while inside a validated token.
    private mutating func apply(_ output: TriggerMachine.Output) -> [GateEffect] {
        guard let session else { return [.dismissPicker] }
        if let shortcode = output.completedShortcode, let typed = output.completedText {
            if transaction != nil {
                // Completed by a drained key: start after the current one ends.
                deferred = .completion(shortcode: shortcode, typed: typed)
                return []
            }
            return beginReplacement(source: .shortcode(shortcode), typed: typed, target: session.target)
        }
        guard output.token != nil else {
            // The token ended; nothing of it is kept.
            self.session = nil
            atBoundary = false
            machine.handle(.reset)
            return [.dismissPicker]
        }
        return refreshPicker()
    }

    private func refreshPicker() -> [GateEffect] {
        guard let session, let token = machine.current.token,
              !token.isDismissed, token.query.count >= minimumQueryLength, transaction == nil
        else {
            return [.dismissPicker]
        }
        return [.presentPicker(query: token.query, anchor: session.anchor)]
    }

    // MARK: Classification

    /// Command, Control and Option chords belong to the host and may move
    /// focus. Shift is part of ordinary typing (`:` is Shift-semicolon).
    static func isChord(_ modifiers: KeyModifiers) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    /// `text` is consulted only for keys that are not navigation or editing
    /// keys, so a Tab or arrow never has its characters read.
    static func classify(_ event: KeyEvent, text: () -> String) -> KeyInput {
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
            let text = text()
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
