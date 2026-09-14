import CoreGraphics

/// What a keyboard or mouse event means to OpenReaction.
public enum KeyInput: Equatable, Sendable {
    case text(String)
    case backspace
    /// The caret may have moved without typing, or focus may have changed.
    case reset
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

/// One text replacement for the app layer to carry out.
public struct Insertion: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The picker's selected suggestion.
        case selection
        /// The emoji for a fully typed `:shortcode:`.
        case shortcode(String)
    }

    public let source: Source
    /// The characters to delete, exactly as typed (including colons).
    public let typed: String
    /// The element that must still have focus when the text is replaced.
    public let target: FocusTarget

    public init(source: Source, typed: String, target: FocusTarget) {
        self.source = source
        self.typed = typed
        self.target = target
    }

    public var replacingCount: Int { typed.count }
}

/// Decides what to do with each keystroke: feed the trigger machine, ask for
/// the focused element, show or move the picker, or insert.
///
/// Pure and synchronous. Side effects come back as `Effect`s for the app layer
/// to run, and asynchronous answers (focus lookups, insertion outcomes) are fed
/// back in. Safety rules live here so they can be tested:
///
/// - Text is captured only while the focused element is known to be editable
///   (`capturesText`). Unknown, unavailable or secure focus captures nothing.
/// - Secure input drops everything, including mid-token.
/// - Insertion needs a focus check for the current token that came back
///   editable, and names the target element so the app layer can verify it.
/// - Picker commands act only when the tap actually swallowed the key; a key
///   the host app also received must not trigger a second action.
public struct TypingCoordinator: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Look up the focused element and call `focusResolved` with the answer.
        case requestFocus(tokenID: Int)
        case presentPicker(query: String, anchor: CGRect)
        case dismissPicker
        case moveSelection(by: Int)
        /// Replace the typed token; call `insertionFinished` with the outcome.
        case insert(Insertion)
        /// The tap swallowed a key the picker could not use; send it on.
        case repost
    }

    public let minimumQueryLength: Int
    private let isSecureInputEnabled: @Sendable () -> Bool
    private let isFrontmostAppExcluded: @Sendable () -> Bool

    private enum Focus: Equatable {
        case unknown
        case secure
        case unavailable
        case editable(anchor: CGRect, target: FocusTarget)
    }

    private struct Session: Equatable {
        let tokenID: Int
        /// Focus as confirmed for this token; nil until the lookup answers.
        var focus: Focus?
        let isExcluded: Bool

        var editable: (anchor: CGRect, target: FocusTarget)? {
            if case .editable(let anchor, let target) = focus { return (anchor, target) }
            return nil
        }
    }

    private var machine = TriggerMachine()
    private var session: Session?
    /// Last known state of the focused element, from `focusChanged`.
    private var focus = Focus.unknown
    /// Set while an insertion is being carried out; input is not interpreted.
    private var pendingInsertion: Insertion?
    /// Mirrors the panel; set by the app layer as the picker shows and hides.
    public var isPickerVisible = false

    public init(
        minimumQueryLength: Int = 2,
        isSecureInputEnabled: @escaping @Sendable () -> Bool,
        isFrontmostAppExcluded: @escaping @Sendable () -> Bool
    ) {
        self.minimumQueryLength = minimumQueryLength
        self.isSecureInputEnabled = isSecureInputEnabled
        self.isFrontmostAppExcluded = isFrontmostAppExcluded
    }

    /// The active token, if any.
    public var token: TriggerMachine.Token? { machine.current.token }

    /// Whether typed characters may be decoded and buffered at all.
    public var capturesText: Bool {
        if case .editable = focus { return true }
        return false
    }

    // MARK: - Focus

    /// The focused element changed, or a probe answered. Anything typed into
    /// a previous element is forgotten.
    public mutating func focusChanged(_ result: FocusResult) -> [Effect] {
        let previous = focus
        focus = Self.focus(from: result)
        if focus == previous, case .editable = focus {
            return []
        }
        return forgetTyping()
    }

    /// Answer to `.requestFocus`. Late answers for an older token are ignored.
    public mutating func focusResolved(tokenID: Int, _ result: FocusResult) -> [Effect] {
        guard var current = session, current.tokenID == tokenID else { return [] }
        let resolved = Self.focus(from: result)
        focus = resolved
        switch resolved {
        case .editable:
            current.focus = resolved
            session = current
            return refreshPicker()
        case .secure, .unavailable, .unknown:
            return forgetTyping()
        }
    }

    private static func focus(from result: FocusResult) -> Focus {
        switch result {
        case .secure: .secure
        case .unavailable: .unavailable
        case .editable(let anchor, let target): .editable(anchor: anchor, target: target)
        }
    }

    // MARK: - Keys

    /// - Parameter swallowed: the tap removed this key from the event stream.
    public mutating func handle(_ input: KeyInput, swallowed: Bool = false) -> [Effect] {
        if isSecureInputEnabled() {
            return (swallowed ? [.repost] : []) + forgetTyping()
        }
        if pendingInsertion != nil {
            // The app layer holds physical keys during a replacement and
            // replays them afterwards, so nothing should arrive here.
            return swallowed ? [.repost] : []
        }
        switch input {
        case .text(let text):
            guard capturesText else { return [] }
            return apply(machine.handle(.text(text)))
        case .backspace:
            guard capturesText else { return [] }
            return apply(machine.handle(.backspace))
        case .reset:
            return forgetTyping()
        case .ignore:
            return []
        case .movePrevious, .moveNext:
            guard swallowed else { return forgetTyping() }
            guard isPickerVisible else { return [.repost] + forgetTyping() }
            return [.moveSelection(by: input == .movePrevious ? -1 : 1)]
        case .confirm:
            guard swallowed else { return forgetTyping() }
            guard isPickerVisible, let token = machine.current.token, let session, let editable = session.editable,
                  session.tokenID == token.id, !session.isExcluded
            else {
                return [.repost] + forgetTyping()
            }
            return beginInsertion(Insertion(source: .selection, typed: token.typed, target: editable.target))
        case .escape:
            guard swallowed else { return forgetTyping() }
            guard isPickerVisible else { return [.repost] + forgetTyping() }
            return apply(machine.handle(.dismiss))
        }
    }

    // MARK: - Insertion

    /// Outcome of an `.insert` effect. On success the typed token is replaced
    /// by `text` in the machine's history; on failure all typing is forgotten.
    public mutating func insertionFinished(_ insertion: Insertion, inserted text: String?) -> [Effect] {
        guard pendingInsertion == insertion else { return [] }
        pendingInsertion = nil
        if let text {
            machine.handle(.replaced(count: insertion.replacingCount, with: text))
            session = nil
            return [.dismissPicker]
        }
        return forgetTyping()
    }

    private mutating func beginInsertion(_ insertion: Insertion) -> [Effect] {
        pendingInsertion = insertion
        session = nil
        return [.dismissPicker, .insert(insertion)]
    }

    // MARK: - Internals

    /// Forget all typing context. Focus knowledge stays; it is owned by `focusChanged`.
    private mutating func forgetTyping() -> [Effect] {
        machine.handle(.reset)
        session = nil
        return [.dismissPicker]
    }

    private mutating func apply(_ output: TriggerMachine.Output) -> [Effect] {
        if let shortcode = output.completedShortcode, let typed = output.completedText {
            guard let session, let editable = session.editable, !session.isExcluded else {
                self.session = nil
                return [.dismissPicker]
            }
            return beginInsertion(Insertion(source: .shortcode(shortcode), typed: typed, target: editable.target))
        }
        guard let token = output.token, !token.isDismissed else {
            session = nil
            return [.dismissPicker]
        }
        var effects: [Effect] = []
        if session?.tokenID != token.id {
            let excluded = isFrontmostAppExcluded()
            session = Session(tokenID: token.id, focus: nil, isExcluded: excluded)
            if !excluded {
                // Re-check the element at the colon: focus may have moved
                // without notice, and the caret position is needed anyway.
                effects.append(.requestFocus(tokenID: token.id))
            }
        }
        return effects + refreshPicker()
    }

    private func refreshPicker() -> [Effect] {
        guard let session, !session.isExcluded, let editable = session.editable,
              let token = machine.current.token, token.id == session.tokenID, !token.isDismissed,
              token.query.count >= minimumQueryLength
        else {
            return [.dismissPicker]
        }
        return [.presentPicker(query: token.query, anchor: editable.anchor)]
    }
}
