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

/// What is known about the element that had keyboard focus when a token started.
public enum FocusResult: Equatable, Sendable {
    /// A password field or similar. Nothing may be observed or inserted.
    case secure
    /// Editable text; `anchor` is where the picker goes (AppKit coordinates).
    case editable(anchor: CGRect)
    /// The focused element could not be read (no focus, timeout, no
    /// Accessibility access). Treated as unsafe: nothing is inserted.
    case unavailable
}

/// Decides what to do with each keystroke: feed the trigger machine, ask for
/// the focused element, show or move the picker, or insert.
///
/// Pure and synchronous. Side effects come back as `Effect`s for the app layer
/// to run, and asynchronous answers (the focus lookup) are fed back in through
/// `focusResolved`. Safety rules live here so they can be tested:
///
/// - While secure input is on, nothing is buffered and nothing happens.
/// - Once the focused element is known to be secure, keystrokes are dropped
///   until focus may have changed (a `.reset` input).
/// - Insertion and the picker require a *completed* focus check that came back
///   editable. Unknown or timed-out focus inserts nothing.
/// - Picker commands act only when the tap actually swallowed the key; a key
///   the host app also received must not trigger a second action.
public struct TypingCoordinator: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Look up the focused element and call `focusResolved` with the answer.
        case requestFocus(tokenID: Int)
        case presentPicker(query: String, anchor: CGRect)
        case dismissPicker
        case moveSelection(by: Int)
        /// Insert the picker's selected suggestion, replacing the typed token.
        case commitSelection(replacing: Int)
        /// Insert the emoji for a fully typed `:shortcode:`.
        case insertShortcode(String, replacing: Int)
        /// The tap swallowed a key the picker could not use; send it on.
        case repost
    }

    public let minimumQueryLength: Int
    private let isSecureInputEnabled: @Sendable () -> Bool
    private let isFrontmostAppExcluded: @Sendable () -> Bool

    private enum Focus: Equatable {
        case pending
        case editable(anchor: CGRect)
        case unavailable
    }

    private struct Session: Equatable {
        let tokenID: Int
        var focus: Focus
        let isExcluded: Bool

        var anchor: CGRect? {
            if case .editable(let anchor) = focus { return anchor }
            return nil
        }
    }

    private var machine = TriggerMachine()
    private var session: Session?
    /// The last focus lookup found a secure field and focus has not moved since.
    private var focusIsSecure = false
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

    // MARK: - Inputs

    /// - Parameter swallowed: the tap removed this key from the event stream.
    public mutating func handle(_ input: KeyInput, swallowed: Bool = false) -> [Effect] {
        if isSecureInputEnabled() {
            return dropEverything(repost: swallowed)
        }
        switch input {
        case .text(let text):
            guard !focusIsSecure else { return [] }
            return apply(machine.handle(.text(text)))
        case .backspace:
            guard !focusIsSecure else { return [] }
            return apply(machine.handle(.backspace))
        case .reset:
            return reset()
        case .ignore:
            return []
        case .movePrevious, .moveNext:
            guard swallowed else { return reset() }
            guard isPickerVisible else { return [.repost] + reset() }
            return [.moveSelection(by: input == .movePrevious ? -1 : 1)]
        case .confirm:
            guard swallowed else { return reset() }
            guard isPickerVisible, let token = machine.current.token, canInsert else {
                return [.repost] + reset()
            }
            return [.commitSelection(replacing: token.typedLength)]
        case .escape:
            guard swallowed else { return reset() }
            guard isPickerVisible else { return [.repost] + reset() }
            return apply(machine.handle(.dismiss))
        }
    }

    /// Answer to `.requestFocus`. Late answers for an older token are ignored.
    public mutating func focusResolved(tokenID: Int, _ result: FocusResult) -> [Effect] {
        guard var current = session, current.tokenID == tokenID else { return [] }
        switch result {
        case .secure:
            focusIsSecure = true
            return dropEverything(repost: false)
        case .unavailable:
            current.focus = .unavailable
            session = current
            return [.dismissPicker]
        case .editable(let anchor):
            current.focus = .editable(anchor: anchor)
            session = current
            return refreshPicker()
        }
    }

    /// The app layer inserted `text` in place of the last `count` typed characters.
    public mutating func didInsert(_ text: String, replacing count: Int) {
        machine.handle(.replaced(count: count, with: text))
        session = nil
    }

    /// Forget all typing context (focus change, click, app switch).
    public mutating func reset() -> [Effect] {
        machine.handle(.reset)
        session = nil
        focusIsSecure = false
        return [.dismissPicker]
    }

    // MARK: - Internals

    /// Like `reset`, but keeps `focusIsSecure` so later keystrokes stay unbuffered.
    private mutating func dropEverything(repost: Bool) -> [Effect] {
        machine.handle(.reset)
        session = nil
        return (repost ? [.repost] : []) + [.dismissPicker]
    }

    private var canInsert: Bool {
        guard let session, session.anchor != nil, !session.isExcluded else { return false }
        return true
    }

    private mutating func apply(_ output: TriggerMachine.Output) -> [Effect] {
        if let shortcode = output.completedShortcode {
            let allowed = canInsert
            session = nil
            var effects: [Effect] = [.dismissPicker]
            if allowed {
                effects.append(.insertShortcode(shortcode, replacing: shortcode.count + 2))
            }
            return effects
        }
        guard let token = output.token, !token.isDismissed else {
            session = nil
            return [.dismissPicker]
        }
        var effects: [Effect] = []
        if session?.tokenID != token.id {
            let excluded = isFrontmostAppExcluded()
            session = Session(tokenID: token.id, focus: .pending, isExcluded: excluded)
            if !excluded {
                effects.append(.requestFocus(tokenID: token.id))
            }
        }
        return effects + refreshPicker()
    }

    private func refreshPicker() -> [Effect] {
        guard let session, !session.isExcluded, let anchor = session.anchor,
              let token = machine.current.token, token.id == session.tokenID, !token.isDismissed,
              token.query.count >= minimumQueryLength
        else {
            return [.dismissPicker]
        }
        return [.presentPicker(query: token.query, anchor: anchor)]
    }
}
