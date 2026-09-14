/// Small string-matching primitives over ASCII-lowercased UTF-8 bytes.
public enum TextMatching {
    /// Lowercased UTF-8 bytes.
    public static func bytes(_ string: String) -> [UInt8] {
        Array(string.lowercased().utf8)
    }

    public static func hasPrefix(_ haystack: [UInt8], _ needle: [UInt8], at start: Int = 0) -> Bool {
        guard start >= 0, haystack.count - start >= needle.count else { return false }
        var offset = 0
        while offset < needle.count {
            if haystack[start + offset] != needle[offset] { return false }
            offset += 1
        }
        return true
    }

    /// Splits on anything that is not a letter or digit, lowercased.
    public static func words(_ string: String) -> [String] {
        string.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Light English suffix stripping so `parties`, `partying` and `party`
    /// meet at `parti`/`party`-like stems. Deliberately conservative: stems
    /// shorter than three characters are left alone.
    public static func stem(_ word: String) -> String {
        var word = word.lowercased()
        func strip(_ suffix: String, replacement: String = "", minimumStem: Int = 3) -> Bool {
            guard word.hasSuffix(suffix), word.count - suffix.count >= minimumStem else { return false }
            word = String(word.dropLast(suffix.count)) + replacement
            return true
        }
        if strip("ies", replacement: "y") { return word }
        if strip("ing") || strip("ed") {
            // Undo consonant doubling: "clapped" -> "clapp" -> "clap".
            if let last = word.last, word.count >= 4, word.dropLast().last == last, !"aeiouls".contains(last) {
                word.removeLast()
            }
            return word
        }
        if strip("es", minimumStem: 4) { return word }
        if word.hasSuffix("ss") { return word }
        _ = strip("s")
        return word
    }

    /// Optimal string alignment distance (Damerau-Levenshtein with adjacent
    /// transpositions), with early exit once it exceeds `limit`.
    public static func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// fzy-style subsequence score, or nil when `needle` is not a subsequence
    /// of `haystack`. Rewards matches at word starts and consecutive runs,
    /// penalizes gaps. Higher is better; results are in roughly 0...100.
    public static func fuzzyScore(_ needle: [UInt8], _ haystack: [UInt8]) -> Int? {
        guard isSubsequence(needle, of: haystack, from: 0) else { return nil }
        return alignmentScore(needle, haystack, from: 0)
    }

    /// Whether `needle` appears in order in `haystack[start...]`.
    @inline(__always)
    static func isSubsequence(_ needle: [UInt8], of haystack: [UInt8], from start: Int) -> Bool {
        guard !needle.isEmpty, haystack.count - start >= needle.count else { return false }
        var matched = 0
        var index = start
        while index < haystack.count && matched < needle.count {
            if haystack[index] == needle[matched] { matched += 1 }
            index += 1
        }
        return matched == needle.count
    }

    /// Best-alignment score of `needle` within `haystack[start...]`; callers
    /// check `isSubsequence` first.
    static func alignmentScore(_ needle: [UInt8], _ haystack: [UInt8], from start: Int) -> Int? {
        let n = needle.count
        let m = haystack.count - start
        guard n > 0, n <= m else { return nil }

        // best[j]: best score with the current needle character placed at j.
        // Choosing the best placement (not the leftmost) lets `thup` use the
        // word-start `u` in `thumbs_up`.
        let unreachable = Int.min / 2
        var previous = [Int](repeating: unreachable, count: m)
        var current = [Int](repeating: unreachable, count: m)
        for i in 0..<n {
            for j in 0..<m {
                current[j] = unreachable
                guard haystack[start + j] == needle[i] else { continue }
                let bonus = (j == 0 || !isAlphanumeric(haystack[start + j - 1])) ? 8 : 1
                if i == 0 {
                    current[j] = bonus
                    continue
                }
                var best = unreachable
                for k in 0..<j where previous[k] > unreachable {
                    let value = k == j - 1
                        ? previous[k] + max(bonus, 6)
                        : previous[k] + bonus - min(j - k - 1, 6)
                    best = max(best, value)
                }
                current[j] = best
            }
            swap(&previous, &current)
        }
        guard let best = previous.max(), best > unreachable else { return nil }
        return max(1, best * 100 / (n * 8))
    }

    @inline(__always)
    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || byte >= 0x80
    }
}
