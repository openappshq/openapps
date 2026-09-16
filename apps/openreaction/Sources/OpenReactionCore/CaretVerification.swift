/// Whether a verified insertion is safe, the field simply cannot be read back
/// (so the caller may fall back to typed replacement), or there is a real
/// mismatch that must refuse.
public enum VerifyDecision: Equatable, Sendable {
    case keystrokes
    case unverifiable
    case refused
}

/// The read-only verification rule, pure so it can be tested without a live
/// Accessibility connection. `CaretLocator.verify` reads the focused element
/// and delegates the decision here; the element must already be confirmed
/// present, same pid, and not secure.
public enum CaretVerification {
    /// - Parameters:
    ///   - typedCount: UTF-16 length of the token the gate holds. Non-empty in
    ///     practice (a token always includes its colon).
    ///   - selection: the selected range, or nil if it could not be read.
    ///   - typed: the token, to compare against the text before the caret.
    ///   - readBefore: reads the `typedCount` units before the caret, or nil if
    ///     they could not be read. Consulted only when the selection is empty
    ///     with room for the token, so its range is never negative.
    ///
    /// Rules:
    /// - No readable selection → `unverifiable`: the tree exposes nothing to
    ///   read back (the Chromium/Electron case), which is not a mismatch.
    /// - A non-empty selection → `refused`: a real selection.
    /// - An empty selection at location 0 while a non-empty token is held →
    ///   `unverifiable`: a field the user just typed into cannot really have an
    ///   empty caret at position 0, so `{0,0}` is a bogus AX answer (some
    ///   Chromium web views report it whatever the real caret) rather than a
    ///   mismatch. The gate still only falls back when the token was typed in
    ///   this focus generation and the app allows it.
    /// - An empty selection with too little text before the caret to hold the
    ///   token → `refused`: a real mismatch (the field genuinely is shorter).
    /// - The text before the caret unreadable → `unverifiable`: still opaque.
    /// - The text before the caret equal to the token → `keystrokes`; otherwise
    ///   `refused`: differing text is a real mismatch.
    public static func decide(
        typedCount: Int, selection: (location: Int, length: Int)?, typed: String, readBefore: () -> String?
    ) -> VerifyDecision {
        guard let selection else { return .unverifiable }
        guard selection.length == 0 else { return .refused }
        if selection.location == 0, typedCount > 0 { return .unverifiable }
        guard selection.location >= typedCount else { return .refused }
        guard let before = readBefore() else { return .unverifiable }
        return before == typed ? .keystrokes : .refused
    }
}
