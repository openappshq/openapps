/// What the picker shows and what gets inserted when a row is chosen.
///
/// Emoji are the only provider today. The shape leaves room for media
/// providers (GIFs, stickers) whose payload cannot be typed as text and will
/// need a different insertion path.
public struct Suggestion: Identifiable, Equatable, Sendable {
    public enum Preview: Equatable, Sendable {
        /// A glyph rendered with the system font, e.g. an emoji.
        case glyph(String)
    }

    public enum Payload: Equatable, Sendable {
        /// Text typed into the focused field.
        case text(String)
    }

    public let id: String
    /// Primary label, e.g. `tada` (rendered as `:tada:`).
    public let title: String
    public let preview: Preview
    public let payload: Payload

    public init(id: String, title: String, preview: Preview, payload: Payload) {
        self.id = id
        self.title = title
        self.preview = preview
        self.payload = payload
    }
}

public protocol SuggestionProvider: Sendable {
    /// Ranked suggestions for a partial query (without the leading colon).
    func suggestions(for query: String, recents: [String], limit: Int) -> [Suggestion]
    /// The suggestion a fully typed `:shortcode:` expands to, if any.
    func exactMatch(for shortcode: String) -> Suggestion?
}

public struct EmojiSuggestionProvider: SuggestionProvider {
    public let matcher: EmojiMatcher

    public init(database: EmojiDatabase) {
        matcher = EmojiMatcher(database: database)
    }

    public func suggestions(for query: String, recents: [String], limit: Int) -> [Suggestion] {
        matcher.matches(for: query, recents: recents, limit: limit).map { match in
            Self.suggestion(match.entry, title: match.shortcode)
        }
    }

    public func exactMatch(for shortcode: String) -> Suggestion? {
        matcher.database.entry(forShortcode: shortcode).map { Self.suggestion($0, title: shortcode.lowercased()) }
    }

    private static func suggestion(_ entry: EmojiEntry, title: String) -> Suggestion {
        Suggestion(id: entry.emoji, title: title, preview: .glyph(entry.emoji), payload: .text(entry.emoji))
    }
}
