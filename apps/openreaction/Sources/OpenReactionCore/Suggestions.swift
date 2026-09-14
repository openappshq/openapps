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
    /// Human-readable name, e.g. "party popper".
    public let subtitle: String
    public let preview: Preview
    public let payload: Payload

    public init(id: String, title: String, subtitle: String = "", preview: Preview, payload: Payload) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.payload = payload
    }
}

public protocol SuggestionProvider: Sendable {
    /// Ranked suggestions for a partial query (without the leading colon).
    /// - Parameter usage: suggestion id → frecency score.
    func suggestions(for query: String, usage: [String: Double], limit: Int) -> [Suggestion]
    /// The suggestion a fully typed `:shortcode:` expands to, if any.
    func exactMatch(for shortcode: String) -> Suggestion?
}

public struct EmojiSuggestionProvider: SuggestionProvider {
    public let search: EmojiSearch

    public init(catalog: EmojiCatalog) {
        search = EmojiSearch(catalog: catalog)
    }

    public var catalog: EmojiCatalog { search.catalog }

    public func suggestions(for query: String, usage: [String: Double], limit: Int) -> [Suggestion] {
        search.matches(for: query, frecency: usage, limit: limit).map { match in
            Self.suggestion(match.record, title: match.shortcode)
        }
    }

    public func exactMatch(for shortcode: String) -> Suggestion? {
        catalog.record(forShortcode: shortcode).map { Self.suggestion($0, title: shortcode.lowercased()) }
    }

    private static func suggestion(_ record: EmojiRecord, title: String) -> Suggestion {
        Suggestion(id: record.emoji, title: title, subtitle: record.name, preview: .glyph(record.emoji), payload: .text(record.emoji))
    }
}
