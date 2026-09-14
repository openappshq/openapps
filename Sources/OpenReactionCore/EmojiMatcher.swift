/// Ranks emoji for a partial shortcode.
///
/// Scores fall into bands so match kinds keep a stable order:
///
/// | Match                                   | Base |
/// | --------------------------------------- | ---- |
/// | exact alias                             | 1000 |
/// | primary shortcode prefix                |  800 |
/// | other alias prefix                      |  700 |
/// | alias word prefix (after `_` or `-`)    |  600 |
/// | keyword prefix (tags, description words)|  400 |
/// | fuzzy subsequence (query of 3+ chars)   |  200 |
///
/// Within a band, shorter candidates win (−1 per extra character, capped at
/// 99). Recently used emoji get up to +150, which can lift an item about one
/// band but never above an exact match.
public struct EmojiMatcher: Sendable {
    public struct Match: Equatable, Sendable {
        public let entry: EmojiEntry
        /// Alias to display, the one that matched when an alias matched.
        public let shortcode: String
        public let score: Int
    }

    public enum Score {
        public static let exact = 1000
        public static let primaryPrefix = 800
        public static let aliasPrefix = 700
        public static let wordPrefix = 600
        public static let keywordPrefix = 400
        public static let fuzzy = 200
        public static let maxRecencyBoost = 150
        public static let recencyStep = 10
        public static let minimumFuzzyQueryLength = 3
    }

    private struct Candidate: Sendable {
        let aliases: [[UInt8]]
        let aliasWordStarts: [[Int]]
        let keywords: [[UInt8]]
    }

    public let database: EmojiDatabase
    private let candidates: [Candidate]

    public init(database: EmojiDatabase) {
        self.database = database
        candidates = database.entries.map { entry in
            let aliases = entry.aliases.map { Array($0.utf8) }
            let wordStarts = aliases.map { bytes in
                bytes.indices.filter { $0 > 0 && (bytes[$0 - 1] == UInt8(ascii: "_") || bytes[$0 - 1] == UInt8(ascii: "-")) }
            }
            var keywords = entry.tags
            keywords.append(contentsOf: entry.description.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return Candidate(aliases: aliases, aliasWordStarts: wordStarts, keywords: keywords.map { Array($0.utf8) })
        }
    }

    /// - Parameters:
    ///   - recents: emoji strings, most recent first.
    public func matches(for query: String, recents: [String] = [], limit: Int = 7) -> [Match] {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty, limit > 0 else { return [] }

        var recencyRank: [String: Int] = [:]
        for (rank, emoji) in recents.enumerated() where recencyRank[emoji] == nil {
            recencyRank[emoji] = rank
        }

        var results: [(index: Int, alias: Int, score: Int)] = []
        results.reserveCapacity(64)
        for (index, candidate) in candidates.enumerated() {
            guard let (baseScore, alias) = Self.score(needle, candidate) else { continue }
            var score = baseScore
            if score < Score.exact, let rank = recencyRank[database.entries[index].emoji] {
                score += max(0, Score.maxRecencyBoost - rank * Score.recencyStep)
            }
            results.append((index, alias, score))
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsLength = candidates[lhs.index].aliases[lhs.alias].count
            let rhsLength = candidates[rhs.index].aliases[rhs.alias].count
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.index < rhs.index
        }

        return results.prefix(limit).map { result in
            let entry = database.entries[result.index]
            return Match(entry: entry, shortcode: entry.aliases[result.alias], score: result.score)
        }
    }

    // MARK: - Scoring

    private static func lengthPenalty(_ candidateLength: Int, _ queryLength: Int) -> Int {
        min(99, candidateLength - queryLength)
    }

    /// Best score for one entry and the alias index to show for it.
    private static func score(_ needle: [UInt8], _ candidate: Candidate) -> (Int, Int)? {
        var best: (score: Int, alias: Int)?
        func consider(_ score: Int, _ alias: Int) {
            if best == nil || score > best!.score { best = (score, alias) }
        }

        for (aliasIndex, alias) in candidate.aliases.enumerated() {
            if alias == needle {
                return (Score.exact, aliasIndex)
            }
            if hasPrefix(alias, needle, at: 0) {
                let base = aliasIndex == 0 ? Score.primaryPrefix : Score.aliasPrefix
                consider(base - lengthPenalty(alias.count, needle.count), aliasIndex)
                continue
            }
            if best.map({ $0.score >= Score.wordPrefix }) == true { continue }
            for start in candidate.aliasWordStarts[aliasIndex] where hasPrefix(alias, needle, at: start) {
                consider(Score.wordPrefix - lengthPenalty(alias.count - start, needle.count), aliasIndex)
                break
            }
        }
        if let best, best.score >= Score.keywordPrefix { return (best.score, best.alias) }

        for keyword in candidate.keywords where hasPrefix(keyword, needle, at: 0) {
            consider(Score.keywordPrefix - lengthPenalty(keyword.count, needle.count), 0)
        }
        if let best { return (best.score, best.alias) }

        guard needle.count >= Score.minimumFuzzyQueryLength else { return nil }
        for (aliasIndex, alias) in candidate.aliases.enumerated() {
            if let score = fuzzyScore(needle, alias, wordStarts: candidate.aliasWordStarts[aliasIndex]) {
                consider(score, aliasIndex)
            }
        }
        return best.map { ($0.score, $0.alias) }
    }

    private static func hasPrefix(_ haystack: [UInt8], _ needle: [UInt8], at start: Int) -> Bool {
        guard haystack.count - start >= needle.count else { return false }
        var offset = 0
        while offset < needle.count {
            if haystack[start + offset] != needle[offset] { return false }
            offset += 1
        }
        return true
    }

    /// In-order subsequence match. The first query character must begin the
    /// alias or one of its words, so `tup` finds `thumbs_up` but `hum` does not.
    private static func fuzzyScore(_ needle: [UInt8], _ alias: [UInt8], wordStarts: [Int]) -> Int? {
        var bestScore: Int?
        let starts = [0] + wordStarts
        for start in starts where alias[start] == needle[0] {
            var position = start + 1
            var gaps = 0
            var matched = 1
            while matched < needle.count && position < alias.count {
                if alias[position] == needle[matched] {
                    matched += 1
                } else {
                    gaps += 1
                }
                position += 1
            }
            guard matched == needle.count else { continue }
            let score = Score.fuzzy - 4 * gaps - lengthPenalty(alias.count, needle.count)
            if score > 0, bestScore.map({ score > $0 }) ?? true {
                bestScore = score
            }
        }
        return bestScore
    }
}
