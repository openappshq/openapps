/// Tracks what the user has typed since the last point where the surrounding
/// text became unknown, and derives whether a `:shortcode` token is in progress.
///
/// The machine never sees the host app's real text. It mirrors a short tail of
/// keystrokes and throws that mirror away whenever the caret may have moved
/// without typing (click, focus change, arrow keys, shortcuts). Deriving the
/// token from that tail on every input keeps backspace handling trivial: delete
/// the last character, then look again.
public struct TriggerMachine: Sendable {
    public struct Token: Equatable, Sendable {
        /// Changes whenever a different `:` starts the token.
        public let id: Int
        /// Lowercased characters after the colon. May be empty.
        public let query: String
        /// The characters as typed, including the colon, e.g. `:TaDa`.
        public let typed: String
        /// The user pressed Escape while this token was active.
        public let isDismissed: Bool

        /// Characters currently in the host text for this token, including the colon.
        public var typedLength: Int { typed.count }
    }

    public enum Input: Equatable, Sendable {
        /// Printable text produced by one key press.
        case text(String)
        case backspace
        /// Surrounding text is unknown from here on.
        case reset
        /// Hide suggestions for the active token until a new token starts.
        case dismiss
        /// The last `count` characters were replaced by `text` (after an insertion).
        case replaced(count: Int, with: String)
    }

    public struct Output: Equatable, Sendable {
        public var token: Token?
        /// Set when a closing colon finished `:query:`. Holds the lowercased query.
        public var completedShortcode: String?
        /// The completed token as typed, including both colons.
        public var completedText: String?

        public init(token: Token? = nil, completedShortcode: String? = nil, completedText: String? = nil) {
            self.token = token
            self.completedShortcode = completedShortcode
            self.completedText = completedText
        }
    }

    public let maxQueryLength: Int
    public let historyLimit: Int

    private var history: [Character] = []
    /// Whether the (possibly trimmed) start of `history` is a word boundary.
    private var historyStartIsBoundary = true
    private var tokenStart: Int?
    private var tokenID = 0
    private var dismissedTokenID: Int?

    public init(maxQueryLength: Int = 30, historyLimit: Int = 64) {
        precondition(historyLimit > maxQueryLength + 1)
        self.maxQueryLength = maxQueryLength
        self.historyLimit = historyLimit
    }

    public private(set) var current = Output()

    @discardableResult
    public mutating func handle(_ input: Input) -> Output {
        var completed: (shortcode: String, text: String)?
        switch input {
        case .text(let text):
            for character in text {
                completed = nil
                if character == ":", let token = current.token, !token.query.isEmpty, !token.isDismissed {
                    completed = (token.query, token.typed + ":")
                }
                append(character)
                refreshToken()
            }
        case .backspace:
            if history.popLast() == nil {
                historyStartIsBoundary = true
            }
            refreshToken()
        case .reset:
            history.removeAll()
            historyStartIsBoundary = true
            refreshToken()
        case .dismiss:
            if let token = current.token {
                dismissedTokenID = token.id
                refreshToken()
            }
        case .replaced(let count, let text):
            if count >= history.count {
                history.removeAll()
                historyStartIsBoundary = true
            } else {
                history.removeLast(count)
            }
            for character in text { append(character) }
            refreshToken()
        }
        current.completedShortcode = completed?.shortcode
        current.completedText = completed?.text
        return current
    }

    // MARK: - Derivation

    private mutating func append(_ character: Character) {
        history.append(character)
        let overflow = history.count - historyLimit
        if overflow > 0 {
            history.removeFirst(overflow)
            historyStartIsBoundary = false
            if let start = tokenStart { tokenStart = start - overflow }
        }
    }

    private mutating func refreshToken() {
        guard let start = trailingTokenStart() else {
            tokenStart = nil
            current.token = nil
            return
        }
        if start != tokenStart || current.token == nil {
            tokenID += 1
        }
        tokenStart = start
        let typed = String(history[start...])
        current.token = Token(id: tokenID, query: String(typed.dropFirst()).lowercased(), typed: typed, isDismissed: dismissedTokenID == tokenID)
    }

    /// Index of the colon that starts the token ending at the caret, if any.
    private func trailingTokenStart() -> Int? {
        var index = history.count - 1
        var queryLength = 0
        while index >= 0 {
            let character = history[index]
            if character == ":" { break }
            guard Self.isShortcodeCharacter(character) else { return nil }
            queryLength += 1
            if queryLength > maxQueryLength { return nil }
            index -= 1
        }
        guard index >= 0 else { return nil }
        let precededByBoundary = index == 0 ? historyStartIsBoundary : Self.isBoundary(history[index - 1])
        return precededByBoundary ? index : nil
    }

    /// Characters allowed inside a shortcode, e.g. `+1`, `flag-us`, `thumbs_up`.
    public static func isShortcodeCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    /// Whether a colon typed after `character` may start a shortcode.
    /// Letters, digits and URL/time punctuation glue the colon to a word:
    /// `http://`, `12:30`, `key:value`, `C:\` never trigger.
    public static func isBoundary(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return false }
        return !nonBoundaryPunctuation.contains(character)
    }

    private static let nonBoundaryPunctuation: Set<Character> = [
        ":", "/", "\\", ".", "_", "-", "+", "@", "#", "&", "=", "?", "%", "~", "$",
    ]
}
