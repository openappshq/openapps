import Foundation

public struct EmojiRecord: Hashable, Sendable {
    public let emoji: String
    /// Display name, localized when the system provides one.
    public let name: String
    /// Shortcodes without colons. The first is shown in the picker.
    public let shortcodes: [String]
    /// Lowercased search words: tags, name words (localized and English).
    public let keywords: [String]
    /// Higher is more commonly used; 0 when unranked.
    public let popularity: Int

    public init(emoji: String, name: String, shortcodes: [String], keywords: [String], popularity: Int = 0) {
        self.emoji = emoji
        self.name = name
        self.shortcodes = shortcodes
        self.keywords = keywords
        self.popularity = popularity
    }
}

public enum EmojiDataSource: Equatable, Sendable, CustomStringConvertible {
    /// The system's CoreEmoji names, in the given localization.
    case macOS(localization: String)
    /// The bundled gemoji list, used when system data is unavailable.
    case gemoji

    public var description: String {
        switch self {
        case .macOS(let localization): "macOS emoji names (\(localization))"
        case .gemoji: "bundled gemoji list"
        }
    }
}

/// The emoji OpenReaction offers, with names, shortcodes and keywords.
///
/// With system data, the set of emoji and their names come from macOS, and
/// gemoji only contributes familiar Slack/GitHub shortcodes (`:+1:`, `:tada:`)
/// and tags for emoji that macOS also has. Emoji without a gemoji alias get a
/// shortcode derived from the English system name (`face_with_bags_under_eyes`).
/// Without system data, gemoji is the whole catalog.
public struct EmojiCatalog: Sendable {
    public let records: [EmojiRecord]
    public let source: EmojiDataSource
    /// Candidates dropped because this system cannot draw them.
    public let unsupportedCount: Int
    private let indexByShortcode: [String: Int]

    public init(records: [EmojiRecord], source: EmojiDataSource, unsupportedCount: Int = 0) {
        self.records = records
        self.source = source
        self.unsupportedCount = unsupportedCount
        var index: [String: Int] = [:]
        for (position, record) in records.enumerated() {
            for shortcode in record.shortcodes where index[shortcode] == nil {
                index[shortcode] = position
            }
        }
        indexByShortcode = index
    }

    public func record(forShortcode shortcode: String) -> EmojiRecord? {
        indexByShortcode[shortcode.lowercased()].map { records[$0] }
    }

    /// - Parameters:
    ///   - apple: system names, or nil to fall back to gemoji alone.
    ///   - isSupported: whether this system renders an emoji string.
    public static func build(
        apple: AppleEmojiData?,
        gemoji: EmojiDatabase,
        isSupported: (String) -> Bool
    ) -> EmojiCatalog {
        var gemojiByKey: [String: EmojiEntry] = [:]
        for entry in gemoji.entries where gemojiByKey[key(entry.emoji)] == nil {
            gemojiByKey[key(entry.emoji)] = entry
        }

        var candidates: [(emoji: String, localizedName: String?, englishName: String?, gemoji: EmojiEntry?)] = []
        let source: EmojiDataSource
        if let apple, !apple.englishNames.isEmpty || !apple.names.isEmpty {
            source = .macOS(localization: apple.localization)
            let keys = Set(apple.names.keys).union(apple.englishNames.keys)
            // Order by gemoji position where known so related emoji stay together, then by scalars.
            let gemojiOrder = Dictionary(gemoji.entries.enumerated().map { (key($0.element.emoji), $0.offset) }, uniquingKeysWith: { first, _ in first })
            let sorted = keys.sorted { lhs, rhs in
                let l = gemojiOrder[key(lhs)] ?? Int.max
                let r = gemojiOrder[key(rhs)] ?? Int.max
                return l != r ? l < r : lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.unicodeScalars.map(\.value))
            }
            var seen = Set<String>()
            for emoji in sorted where seen.insert(key(emoji)).inserted {
                let match = gemojiByKey[key(emoji)]
                candidates.append((
                    preferredForm(emoji, match?.emoji),
                    apple.names[emoji],
                    apple.englishNames[emoji],
                    match
                ))
            }
        } else {
            source = .gemoji
            candidates = gemoji.entries.map { ($0.emoji, nil, nil, $0) }
        }

        var records: [EmojiRecord] = []
        records.reserveCapacity(candidates.count)
        var unsupported = 0
        var usedShortcodes = Set<String>()
        for candidate in candidates {
            guard isSupported(candidate.emoji) else {
                unsupported += 1
                continue
            }
            let englishName = candidate.englishName ?? candidate.gemoji?.description ?? unicodeName(candidate.emoji)
            let name = candidate.localizedName ?? englishName ?? candidate.gemoji?.primaryShortcode ?? candidate.emoji

            var shortcodes = candidate.gemoji?.aliases ?? []
            if let englishName {
                let derived = derivedShortcode(englishName)
                if !derived.isEmpty && !shortcodes.contains(derived) && !usedShortcodes.contains(derived) {
                    shortcodes.append(derived)
                }
            }
            shortcodes.removeAll { usedShortcodes.contains($0) }
            guard !shortcodes.isEmpty else { continue }
            usedShortcodes.formUnion(shortcodes)

            var keywords: [String] = []
            var seenKeywords = Set<String>()
            let words = (candidate.gemoji?.tags ?? [])
                + TextMatching.words(name)
                + TextMatching.words(englishName ?? "")
            for word in words where seenKeywords.insert(word).inserted {
                keywords.append(word)
            }

            records.append(EmojiRecord(
                emoji: candidate.emoji,
                name: name,
                shortcodes: shortcodes,
                keywords: keywords,
                popularity: EmojiPopularity.score(key(candidate.emoji))
            ))
        }
        return EmojiCatalog(records: records, source: source, unsupportedCount: unsupported)
    }

    /// `thumbs up` → `thumbs_up`, `flag: Côte d’Ivoire` → `flag_cote_d_ivoire`.
    public static func derivedShortcode(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator && !result.isEmpty { result.append("_") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    /// Identity used to match the same emoji across data sets that disagree
    /// on variation selectors.
    static func key(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
    }

    /// Keeps the emoji-presentation selector when either source has it, so
    /// characters like ❤️ insert as emoji rather than text glyphs.
    private static func preferredForm(_ apple: String, _ gemoji: String?) -> String {
        guard let gemoji else { return apple }
        let appleHasSelector = apple.unicodeScalars.contains { $0.value == 0xFE0F }
        let gemojiHasSelector = gemoji.unicodeScalars.contains { $0.value == 0xFE0F }
        return !appleHasSelector && gemojiHasSelector ? gemoji : apple
    }

    private static func unicodeName(_ emoji: String) -> String? {
        let names = emoji.unicodeScalars
            .filter { $0.value != 0xFE0F && $0.value != 0x200D }
            .compactMap { $0.properties.name?.lowercased() }
        return names.isEmpty ? nil : names.joined(separator: " ")
    }
}

/// A small prior for commonly used emoji, so ties favor what people usually mean.
enum EmojiPopularity {
    static let ranked: [String] = [
        "😂", "❤", "🤣", "👍", "😭", "🙏", "😘", "🥰", "😍", "😊",
        "🎉", "😁", "💕", "🥺", "😅", "🔥", "☺", "🤦", "♥", "🤷",
        "🙄", "😆", "🤗", "😉", "🎂", "🤔", "👏", "🙂", "😳", "🥳",
        "😎", "👌", "💜", "😔", "💪", "✨", "💖", "👀", "😋", "😏",
        "😢", "👉", "💗", "😩", "💯", "🌹", "💞", "🎈", "💙", "😃",
        "😡", "💐", "😜", "🙈", "🤞", "😄", "🤤", "🙌", "🤪", "❣",
        "😀", "💋", "💀", "👇", "💔", "😌", "💓", "🤩", "🙃", "😬",
        "😱", "😴", "🤭", "😐", "🌞", "😒", "😇", "🌸", "😈", "🎶",
        "✌", "🎊", "🥵", "😞", "💚", "☀", "🖤", "💰", "😚", "👑",
        "🎁", "💥", "🙋", "☹", "😑", "🥴", "👈", "💩", "✅", "👋",
    ]

    private static let scores: [String: Int] = Dictionary(
        ranked.enumerated().map { (EmojiCatalog.key($0.element), ranked.count - $0.offset) },
        uniquingKeysWith: { first, _ in first }
    )

    static func score(_ key: String) -> Int {
        scores[key] ?? 0
    }
}
