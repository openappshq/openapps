/// Whether a verified insertion is safe, the field simply cannot be read back
/// (so the caller may fall back to typed replacement), or there is a real
/// mismatch that must refuse.
public enum VerifyDecision: Equatable, Sendable {
    case keystrokes
    case unverifiable
    case refused
}

/// How an Accessibility string attribute (`AXRole`, `AXSubrole`) answered. The
/// distinction matters for the typed-replacement fallback: only a *positively
/// readable* classification may authorize typing into a field whose contents
/// cannot be read back. A missing attribute is not the same as an unreadable
/// one, and neither is the same as a value that came back.
public enum AXStringAnswer: Equatable, Sendable {
    /// A well-formed string value came back.
    case value(String)
    /// The attribute is genuinely absent (`kAXErrorNoValue` /
    /// `kAXErrorAttributeUnsupported`): the element does not carry it.
    case absent
    /// The question could not be answered — an error, a timeout, or a
    /// `success` carrying nil or a non-string (malformed). Treated as unsafe.
    case unreadable
}

/// The read-only verification rule, pure so it can be tested without a live
/// Accessibility connection. `CaretLocator.verify` reads the focused element
/// and delegates the decision here; the element must already be confirmed
/// present with the same pid.
public enum CaretVerification {
    /// The subrole macOS gives password fields.
    public static let secureTextFieldSubrole = "AXSecureTextField"
    /// Roles whose contents the user edits by typing. Only these may authorize
    /// the typed-replacement fallback into an unreadable field. `AXSearchField`
    /// is included per the fallback contract even though macOS also exposes it
    /// as a subrole of `AXTextField`.
    public static let editableTextRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// The probe's secure classification, shared with `CaretLocator` so both
    /// paths read a subrole the same way: true when positively a secure field,
    /// false when positively not one (a readable non-secure subrole, or one
    /// genuinely absent), nil when the answer could not be trusted (the field
    /// might be secure). Fail-closed: nil keeps capture shut.
    public static func isSecure(subrole: AXStringAnswer) -> Bool? {
        switch subrole {
        case .value(let value): value == secureTextFieldSubrole
        case .absent: false
        case .unreadable: nil
        }
    }

    /// - Parameters:
    ///   - role: the `AXRole` answer.
    ///   - subrole: the `AXSubrole` answer.
    ///   - typedCount: UTF-16 length of the token the gate holds. Non-empty in
    ///     practice (a token always includes its colon).
    ///   - selection: the selected range, or nil if it could not be read.
    ///   - typed: the token, to compare against the text before the caret.
    ///   - textBeforeCaret: reads `length` units starting at `location`, or nil
    ///     if that could not be read. Called only with valid (non-negative)
    ///     ranges: the `(location - typedCount, typedCount)` run before a caret
    ///     with room for it, or `(0, 0)` for the zero-caret case.
    ///
    /// Rules, in order:
    /// - A positively secure subrole → `refused`: never touch a password field.
    /// - Otherwise the reads decide the *shape* (verified / real mismatch /
    ///   fallback candidate); a fallback candidate becomes `unverifiable` only
    ///   when the field positively classifies as an editable, non-secure text
    ///   field, and `refused` otherwise. So an unreadable or non-text role, or
    ///   an unreadable subrole, never authorizes typing into an opaque field.
    ///
    /// Shape from the reads:
    /// - No readable selection → fallback candidate: the tree exposes nothing.
    /// - A non-empty selection → `refused`: a real selection.
    /// - An empty selection at location 0 with a non-empty token: read `(0, 0)`.
    ///   Readable-and-empty is the specified bogus `{0,0}` (a field the user
    ///   just typed into cannot really be empty at position 0) → fallback
    ///   candidate; unreadable there → fallback candidate (opaque); a non-empty
    ///   answer for a zero-length range is malformed → `refused`.
    /// - An empty selection with too little text before the caret → `refused`.
    /// - The text before the caret equal to the token → `keystrokes`; different
    ///   → `refused`; unreadable → fallback candidate (opaque).
    public static func decide(
        role: AXStringAnswer,
        subrole: AXStringAnswer,
        typedCount: Int,
        selection: (location: Int, length: Int)?,
        typed: String,
        textBeforeCaret: (_ location: Int, _ length: Int) -> String?
    ) -> VerifyDecision {
        if isSecure(subrole: subrole) == true { return .refused }
        switch shape(typedCount: typedCount, selection: selection, typed: typed, textBeforeCaret: textBeforeCaret) {
        case .keystrokes: return .keystrokes
        case .refused: return .refused
        case .fallbackCandidate: return canFallBack(role: role, subrole: subrole) ? .unverifiable : .refused
        }
    }

    private enum Shape { case keystrokes, refused, fallbackCandidate }

    private static func shape(
        typedCount: Int, selection: (location: Int, length: Int)?, typed: String,
        textBeforeCaret: (_ location: Int, _ length: Int) -> String?
    ) -> Shape {
        guard let selection else { return .fallbackCandidate }
        guard selection.length == 0 else { return .refused }
        if selection.location == 0 {
            guard typedCount > 0 else { return .refused }
            switch textBeforeCaret(0, 0) {
            case .some(""): return .fallbackCandidate // readable-and-empty: the bogus {0,0}
            case .none: return .fallbackCandidate     // unreadable before-text at caret 0: opaque
            case .some: return .refused               // malformed: non-empty for a zero-length range
            }
        }
        guard selection.location >= typedCount else { return .refused }
        switch textBeforeCaret(selection.location - typedCount, typedCount) {
        case .some(let before): return before == typed ? .keystrokes : .refused
        case .none: return .fallbackCandidate
        }
    }

    /// Whether the fallback may type into a field it cannot read back: the role
    /// must positively be an editable text role, and the subrole must be a
    /// readable non-secure value or genuinely absent. Any unreadable answer, or
    /// a non-text role, refuses.
    private static func canFallBack(role: AXStringAnswer, subrole: AXStringAnswer) -> Bool {
        guard case .value(let role) = role, editableTextRoles.contains(role) else { return false }
        switch subrole {
        case .value(let value): return value != secureTextFieldSubrole
        case .absent: return true
        case .unreadable: return false
        }
    }
}
