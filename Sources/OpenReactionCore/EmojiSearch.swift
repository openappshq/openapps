/// Ranks catalog emoji for a partial query.
///
/// Every candidate lands in the best tier it qualifies for; tiers never mix.
///
/// | Tier | Match                                                        |
/// | ---- | ------------------------------------------------------------ |
/// | 0    | exact shortcode (`:tada`, `:+1`)                             |
/// | 1    | shortcode prefix (`:thumbs` → `thumbsup`)                    |
/// | 2    | word prefix in the name or a shortcode (`:popper`)           |
/// | 3    | exact keyword                                                |
/// | 4    | keyword prefix                                               |
/// | 5    | same English stem as a keyword or name word (`:parties`)     |
/// | 6    | fuzzy subsequence, 3+ characters (`:thmup`)                  |
/// | 7    | one typo, 4+ characters (`:hart` → `heart`)                  |
///
/// Within a tier: frecency, then popularity, then fuzzy quality, then the
/// shorter matched text, then catalog order. In the fuzzy tier, match quality
/// comes first.
public struct EmojiSearch: Sendable {
    public enum Tier: Int, Comparable, Sendable, CaseIterable {
        case exactShortcode, shortcodePrefix, wordPrefix, exactKeyword, keywordPrefix, stem, fuzzy, typo

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Match: Equatable, Sendable {
        public let record: EmojiRecord
        public let tier: Tier
        /// The shortcode to show: the one that matched, else the record's first.
        public let shortcode: String
    }

    public static let minimumFuzzyLength = 3
    /// Fuzzy hits scoring below this (long gaps, few runs) are dropped so a
    /// near-miss typo of a short word is not outranked by a scattered match.
    public static let minimumFuzzyQuality = 56
    public static let minimumTypoLength = 4

    private struct Indexed: Sendable {
        let shortcodes: [[UInt8]]
        /// Indexes where a word begins inside each shortcode, including 0.
        let shortcodeWordStarts: [[Int]]
        /// Indexes where a word begins inside the lowercased name, including 0.
        let nameWordStarts: [Int]
        let nameWords: [[UInt8]]
        let keywords: [[UInt8]]
        let stems: [[UInt8]]
        let name: [UInt8]
    }

    public let catalog: EmojiCatalog
    private let indexed: [Indexed]

    public init(catalog: EmojiCatalog) {
        self.catalog = catalog
        indexed = catalog.records.map { record in
            let shortcodes = record.shortcodes.map(TextMatching.bytes)
            let wordStarts = shortcodes.map { bytes in
                bytes.indices.filter { $0 == 0 || bytes[$0 - 1] == UInt8(ascii: "_") || bytes[$0 - 1] == UInt8(ascii: "-") }
            }
            let name = TextMatching.bytes(record.name)
            let nameWords = TextMatching.words(record.name)
            var stems = Set<String>()
            for word in record.keywords + nameWords { stems.insert(TextMatching.stem(word)) }
            return Indexed(
                shortcodes: shortcodes,
                shortcodeWordStarts: wordStarts,
                nameWordStarts: name.indices.filter { $0 == 0 || !TextMatching.isAlphanumeric(name[$0 - 1]) },
                nameWords: nameWords.map(TextMatching.bytes),
                keywords: record.keywords.map(TextMatching.bytes),
                stems: stems.sorted().map(TextMatching.bytes),
                name: name
            )
        }
    }

    /// - Parameter frecency: emoji string → frecency score (see `Frecency`).
    public func matches(for query: String, frecency: [String: Double] = [:], limit: Int = 7) -> [Match] {
        let needle = TextMatching.bytes(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let stemmed = TextMatching.bytes(TextMatching.stem(query))

        struct Scored {
            let index: Int
            let tier: Tier
            let shortcode: Int?
            let quality: Int
            let length: Int
            let frecency: Double
        }

        var scored: [Scored] = []
        scored.reserveCapacity(64)
        for (index, item) in indexed.enumerated() {
            guard let found = Self.bestMatch(needle, stemmed: stemmed, item) else { continue }
            let record = catalog.records[index]
            scored.append(Scored(
                index: index,
                tier: found.tier,
                shortcode: found.shortcode,
                quality: found.quality,
                length: found.length,
                frecency: frecency[record.emoji] ?? 0
            ))
        }

        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            // In the fuzzy tier a tight match beats a loose one before usage counts.
            if lhs.tier == .fuzzy, lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
            let lhsPopularity = catalog.records[lhs.index].popularity
            let rhsPopularity = catalog.records[rhs.index].popularity
            if lhsPopularity != rhsPopularity { return lhsPopularity > rhsPopularity }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.index < rhs.index
        }

        return scored.prefix(limit).map { item in
            let record = catalog.records[item.index]
            return Match(record: record, tier: item.tier, shortcode: record.shortcodes[item.shortcode ?? 0])
        }
    }

    // MARK: - Tiering

    private struct Found {
        let tier: Tier
        let shortcode: Int?
        var quality = 0
        let length: Int
    }

    private static func bestMatch(_ needle: [UInt8], stemmed: [UInt8], _ item: Indexed) -> Found? {
        // Tier 0 and 1: shortcodes.
        var prefix: Found?
        for (position, shortcode) in item.shortcodes.enumerated() {
            if shortcode == needle {
                return Found(tier: .exactShortcode, shortcode: position, length: shortcode.count)
            }
            if prefix == nil || shortcode.count < prefix!.length, TextMatching.hasPrefix(shortcode, needle) {
                prefix = Found(tier: .shortcodePrefix, shortcode: position, length: shortcode.count)
            }
        }
        if let prefix { return prefix }

        // Tier 2: a word in the name, or a word inside a shortcode.
        for word in item.nameWords where TextMatching.hasPrefix(word, needle) {
            return Found(tier: .wordPrefix, shortcode: nil, length: item.name.count)
        }
        for (position, shortcode) in item.shortcodes.enumerated() {
            for start in item.shortcodeWordStarts[position] where TextMatching.hasPrefix(shortcode, needle, at: start) {
                return Found(tier: .wordPrefix, shortcode: position, length: shortcode.count)
            }
        }

        // Tiers 3 and 4: keywords.
        var keywordPrefix: Found?
        for keyword in item.keywords {
            if keyword == needle {
                return Found(tier: .exactKeyword, shortcode: nil, length: keyword.count)
            }
            if keywordPrefix == nil, TextMatching.hasPrefix(keyword, needle) {
                keywordPrefix = Found(tier: .keywordPrefix, shortcode: nil, length: keyword.count)
            }
        }
        if let keywordPrefix { return keywordPrefix }

        // Tier 5: stems.
        if stemmed.count >= 3, item.stems.contains(stemmed) {
            return Found(tier: .stem, shortcode: nil, length: item.name.count)
        }

        // Tier 6: fuzzy subsequence over shortcodes and the name, anchored at a word start.
        if needle.count >= minimumFuzzyLength {
            var best: Found?
            for (position, shortcode) in item.shortcodes.enumerated() {
                if let score = anchoredFuzzy(needle, shortcode, starts: item.shortcodeWordStarts[position]),
                   best == nil || score > best!.quality {
                    best = Found(tier: .fuzzy, shortcode: position, quality: score, length: shortcode.count)
                }
            }
            if let score = anchoredFuzzy(needle, item.name, starts: item.nameWordStarts), best == nil || score > best!.quality {
                best = Found(tier: .fuzzy, shortcode: nil, quality: score, length: item.name.count)
            }
            if let best { return best }
        }

        // Tier 7: one edit away from a shortcode, name word or keyword.
        if needle.count >= minimumTypoLength {
            for (position, shortcode) in item.shortcodes.enumerated()
            where TextMatching.editDistance(needle, shortcode, limit: 1) <= 1 {
                return Found(tier: .typo, shortcode: position, length: shortcode.count)
            }
            for words in [item.nameWords, item.keywords] {
                for word in words where TextMatching.editDistance(needle, word, limit: 1) <= 1 {
                    return Found(tier: .typo, shortcode: nil, length: word.count)
                }
            }
        }
        return nil
    }

    /// Fuzzy score only when the first query character begins the text or one of its words.
    private static func anchoredFuzzy(_ needle: [UInt8], _ text: [UInt8], starts: [Int]) -> Int? {
        guard let first = starts.first(where: { text[$0] == needle[0] }),
              TextMatching.isSubsequence(needle, of: text, from: first) else { return nil }
        var best: Int?
        for start in starts where start >= first && text[start] == needle[0] {
            if let score = TextMatching.alignmentScore(needle, text, from: start), score >= minimumFuzzyQuality,
               best.map({ score > $0 }) ?? true {
                best = score
            }
        }
        return best
    }
}
