import Foundation
import OpenReactionCore
import Testing

@Suite("Emoji matcher")
struct EmojiMatcherTests {
    static let bundled = try! EmojiDatabase.bundled()

    private let small = EmojiDatabase(entries: [
        EmojiEntry(emoji: "😄", description: "grinning face with smiling eyes", category: "", aliases: ["smile"], tags: ["happy", "joy"]),
        EmojiEntry(emoji: "😺", description: "grinning cat", category: "", aliases: ["smiley_cat"], tags: []),
        EmojiEntry(emoji: "🙂", description: "slightly smiling face", category: "", aliases: ["slightly_smiling_face"], tags: []),
        EmojiEntry(emoji: "👍", description: "thumbs up", category: "", aliases: ["+1", "thumbsup"], tags: ["approve", "ok"]),
        EmojiEntry(emoji: "🎉", description: "party popper", category: "", aliases: ["tada"], tags: ["hooray", "party"]),
        EmojiEntry(emoji: "😃", description: "grinning face with big eyes", category: "", aliases: ["smiley"], tags: ["happy"]),
        EmojiEntry(emoji: "🥳", description: "partying face", category: "", aliases: ["partying_face"], tags: ["celebration"]),
    ])

    private func shortcodes(_ query: String, recents: [String] = [], database: EmojiDatabase? = nil) -> [String] {
        EmojiMatcher(database: database ?? small).matches(for: query, recents: recents, limit: 10).map(\.shortcode)
    }

    @Test func bundledDatasetLoads() {
        #expect(Self.bundled.entries.count > 1800)
        #expect(Self.bundled.entry(forShortcode: "tada")?.emoji == "🎉")
        #expect(Self.bundled.entry(forShortcode: "TADA")?.emoji == "🎉")
        #expect(Self.bundled.entry(forShortcode: "+1")?.emoji == "👍")
    }

    @Test func emptyQueryHasNoMatches() {
        #expect(shortcodes("").isEmpty)
    }

    @Test func exactBeatsPrefix() {
        #expect(shortcodes("smile").first == "smile")
    }

    @Test func primaryPrefixOrderedByLength() {
        #expect(Array(shortcodes("smi").prefix(3)) == ["smile", "smiley", "smiley_cat"])
    }

    @Test func secondaryAliasPrefixMatchesAndIsDisplayed() {
        #expect(shortcodes("thumbs") == ["thumbsup"])
    }

    @Test func primaryPrefixBeatsSecondaryAliasPrefix() {
        let database = EmojiDatabase(entries: [
            EmojiEntry(emoji: "A", description: "", category: "", aliases: ["zzz", "okay"], tags: []),
            EmojiEntry(emoji: "B", description: "", category: "", aliases: ["okayish"], tags: []),
        ])
        #expect(shortcodes("oka", database: database) == ["okayish", "okay"])
    }

    @Test func wordPrefixMatchesInsideAlias() {
        #expect(shortcodes("cat").first == "smiley_cat")
        // Alias word matches first, then emoji whose description mentions "face".
        #expect(Array(shortcodes("face").prefix(2)) == ["partying_face", "slightly_smiling_face"])
    }

    @Test func aliasMatchesBeatKeywordMatches() {
        let database = EmojiDatabase(entries: [
            EmojiEntry(emoji: "K", description: "", category: "", aliases: ["zebra"], tags: ["party"]),
            EmojiEntry(emoji: "W", description: "", category: "", aliases: ["big_party_hat"], tags: []),
        ])
        #expect(shortcodes("party", database: database) == ["big_party_hat", "zebra"])
    }

    @Test func keywordMatchesTagsAndDescriptionWords() {
        #expect(shortcodes("hooray") == ["tada"])
        #expect(shortcodes("popper") == ["tada"])
    }

    @Test func fuzzyNeedsThreeCharacters() {
        #expect(shortcodes("sf").isEmpty)
        #expect(shortcodes("ssf").contains("slightly_smiling_face"))
    }

    @Test func fuzzyMustStartAtWordStart() {
        #expect(!shortcodes("mil").contains("smile"))
    }

    @Test func fuzzyRanksBelowPrefix() {
        let results = shortcodes("smil")
        #expect(results.first == "smile")
        #expect(results.last == "slightly_smiling_face")
    }

    @Test func recentUseBoostsWithinReach() {
        #expect(Array(shortcodes("smi", recents: ["😺"]).prefix(2)) == ["smiley_cat", "smile"])
    }

    @Test func recentUseNeverBeatsExactMatch() {
        #expect(shortcodes("smile", recents: ["😃"]).first == "smile")
    }

    @Test func limitIsRespected() {
        #expect(EmojiMatcher(database: Self.bundled).matches(for: "s", limit: 7).count == 7)
    }

    @Test func realDatasetRanksCommonShortcodes() {
        let matcher = EmojiMatcher(database: Self.bundled)
        #expect(matcher.matches(for: "tada").first?.entry.emoji == "🎉")
        #expect(matcher.matches(for: "thu").first?.entry.emoji == "👍")
        #expect(matcher.matches(for: "heart").first?.entry.emoji == "❤️")
        #expect(matcher.matches(for: "joy").first?.entry.emoji == "😂")
    }

    /// The whole set must rank well within one frame. Debug builds are several
    /// times slower than release, so the bound here is generous; run
    /// `swift test -c release` to check the 5 ms release target.
    @Test func matchingIsFast() {
        let matcher = EmojiMatcher(database: Self.bundled)
        let queries = ["s", "sm", "smi", "heart", "thumbs", "xyzq", "face", "flag", "party_popper", "ssf"]
        let clock = ContinuousClock()
        var worst = Duration.zero
        for query in queries {
            let elapsed = clock.measure { _ = matcher.matches(for: query, recents: ["🎉", "👍"]) }
            worst = max(worst, elapsed)
        }
        #if DEBUG
        let budget = Duration.milliseconds(50)
        #else
        let budget = Duration.milliseconds(5)
        #endif
        #expect(worst < budget, "slowest query took \(worst)")
    }
}
