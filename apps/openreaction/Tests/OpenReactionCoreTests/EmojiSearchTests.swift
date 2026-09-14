import Foundation
@testable import OpenReactionCore
import Testing

/// Hand-written stand-ins for the system's English emoji names. Real system
/// files are never read or bundled by tests.
enum Fixtures {
    static let englishNames: [String: String] = [
        "🎉": "party popper",
        "🥳": "partying face",
        "🎊": "confetti ball",
        "👍": "thumbs up",
        "👎": "thumbs down",
        "❤️": "red heart",
        "💔": "broken heart",
        "😆": "grinning squinting face",
        "😂": "face with tears of joy",
        "🔥": "fire",
        "🧯": "fire extinguisher",
        "😄": "grinning face with smiling eyes",
        "😃": "grinning face with big eyes",
        "😏": "smirking face",
        "😼": "cat with wry smile",
        "😺": "grinning cat",
        "🫩": "face with bags under eyes",
        "👏": "clapping hands",
        "™️": "trade mark",
        "🔣": "input symbols",
        "👨‍👨‍👧": "family: man, man, girl",
        "👩‍👩‍👧‍👦": "family: woman, woman, girl, boy",
        "🏷️": "label",
        "🎯": "bullseye",
        "🎟️": "admission tickets",
    ]

    static let gemoji = try! EmojiDatabase.bundled()

    static func catalog(
        names: [String: String]? = englishNames,
        localized: [String: String]? = nil,
        supported: @escaping (String) -> Bool = { _ in true }
    ) -> EmojiCatalog {
        let apple = names.map {
            AppleEmojiData(localization: localized == nil ? "en" : "de", names: localized ?? $0, englishNames: $0)
        }
        return EmojiCatalog.build(apple: apple, gemoji: gemoji, isSupported: supported)
    }
}

@Suite("Emoji search")
struct EmojiSearchTests {
    let search = EmojiSearch(catalog: Fixtures.catalog())

    private func top(_ query: String, frecency: [String: Double] = [:], limit: Int = 7) -> [EmojiSearch.Match] {
        search.matches(for: query, frecency: frecency, limit: limit)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let query: String
        let first: String
        let tier: EmojiSearch.Tier
        var testDescription: String { ":\(query)" }
    }

    @Test(arguments: [
        Case(query: "tada", first: "🎉", tier: .exactShortcode),
        Case(query: "+1", first: "👍", tier: .exactShortcode),
        Case(query: "laughing", first: "😆", tier: .exactShortcode),
        Case(query: "fire", first: "🔥", tier: .exactShortcode),
        Case(query: "thumbs", first: "👍", tier: .shortcodePrefix),
        Case(query: "party", first: "🎉", tier: .shortcodePrefix),
        Case(query: "popper", first: "🎉", tier: .wordPrefix),
        Case(query: "bags", first: "🫩", tier: .wordPrefix),
        Case(query: "hooray", first: "🎉", tier: .exactKeyword),
        Case(query: "celebr", first: "🥳", tier: .keywordPrefix),
        Case(query: "parties", first: "🎉", tier: .stem),
        Case(query: "clapped", first: "👏", tier: .stem),
        // "hart" is a loose subsequence of "heart" (below the fuzzy floor), so
        // it lands in the typo tier.
        Case(query: "hart", first: "❤️", tier: .typo),
        Case(query: "haert", first: "❤️", tier: .typo),
        // "firr" would loosely fuzzy-match fire_extinguisher; the quality floor rejects that.
        Case(query: "firr", first: "🔥", tier: .typo),
    ])
    func rankingTiers(_ testCase: Case) {
        let first = top(testCase.query).first
        #expect(first?.record.emoji == testCase.first)
        #expect(first?.tier == testCase.tier)
    }

    @Test func loosePrefixTyposDoNotSurfaceAsFuzzy() {
        // `tad` is a subsequence of `trade_mark` but scattered; only 🎉 matches.
        let tad = top("tad").map(\.record.emoji)
        #expect(tad.first == "🎉")
        #expect(!tad.contains("™️"))
        #expect(!tad.contains("🔣"))
    }

    @Test func exactShortcodeIsNotFollowedByFamilyNoise() {
        let tada = top("tada").map(\.record.emoji)
        #expect(tada == ["🎉"])
    }

    @Test func weakTiersOnlyFillWhenStrongTiersAreThin() {
        // `fire` has ≥4 strong matches in the full set, so no fuzzy/typo rows.
        let full = EmojiSearch(catalog: EmojiCatalog.build(apple: nil, gemoji: Fixtures.gemoji, isSupported: { _ in true }))
        let fire = full.matches(for: "fire", limit: 12)
        #expect(fire.count >= 4)
        #expect(fire.allSatisfy { $0.tier <= .stem })
        // `hart` has no strong matches, so the typo tier fills in.
        #expect(full.matches(for: "hart").first?.tier == .typo)
    }

    @Test func partyShowsBothPartyEmojiFirst() {
        #expect(Set(top("party").prefix(2).map(\.record.emoji)) == ["🎉", "🥳"])
    }

    @Test func tiersNeverInterleave() {
        let tiers = top("fire", limit: 20).map(\.tier)
        #expect(tiers == tiers.sorted())
    }

    @Test func matchedShortcodeIsDisplayed() {
        #expect(top("thumbsu").first?.shortcode == "thumbsup")
        #expect(top("thumbs_u").first?.shortcode == "thumbs_up")
        #expect(top("tada").first?.shortcode == "tada")
    }

    @Test func frecencyReordersWithinATier() {
        // 😃 smiley and 😄 smile share the prefix tier; 😃 ranks higher in the popularity prior.
        #expect(top("smil").first?.record.emoji == "😃")
        #expect(top("smil", frecency: ["😄": 2]).first?.record.emoji == "😄")
    }

    @Test func frecencyNeverCrossesTiers() {
        #expect(top("fire", frecency: ["🧯": 50]).first?.record.emoji == "🔥")
    }

    @Test func popularityBreaksTiesBeforeLength() {
        // Both have the "heart" shortcode word; ❤️ is in the popularity prior.
        let hearts = top("heart").map(\.record.emoji)
        #expect(hearts.first == "❤️")
    }

    @Test func fuzzyRequiresThreeCharactersAndAWordStart() {
        #expect(top("tu").allSatisfy { $0.tier != .fuzzy })
        #expect(top("thup").first?.record.emoji == "👍")
        #expect(top("thup").first?.tier == .fuzzy)
        #expect(!top("ada").contains { $0.record.emoji == "🎉" && $0.tier == .fuzzy })
    }

    @Test func typoToleranceNeedsFourCharacters() {
        #expect(top("fir").allSatisfy { $0.tier != .typo })
    }

    @Test func emptyAndUnknownQueries() {
        #expect(top("").isEmpty)
        #expect(top("zzzzqqq").isEmpty)
    }

    @Test func limitIsRespected() {
        #expect(top("face", limit: 3).count == 3)
    }

    /// Unoptimized debug code cannot meet the per-keystroke budget, so this
    /// only asserts in release: `swift test -c release`.
    @Test(.enabled(if: isReleaseBuild, "performance budget applies to release builds"))
    func searchIsFastOnTheFullGemojiSet() {
        let full = EmojiSearch(catalog: EmojiCatalog.build(apple: nil, gemoji: Fixtures.gemoji, isSupported: { _ in true }))
        let clock = ContinuousClock()
        var worst = Duration.zero
        for query in ["s", "sm", "smi", "heart", "thumbs", "xyzq", "face", "flag", "hart", "parties", "thmup"] {
            worst = max(worst, clock.measure { _ = full.matches(for: query, frecency: ["🎉": 1, "👍": 3]) })
        }
        #expect(worst < .milliseconds(5), "slowest query took \(worst)")
    }

    private static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
}

@Suite("Text matching")
struct TextMatchingTests {
    @Test(arguments: [
        ("parties", "party"), ("party", "party"), ("partying", "party"), ("clapped", "clap"),
        ("hearts", "heart"), ("kisses", "kiss"), ("glass", "glass"), ("cats", "cat"), ("red", "red"),
    ])
    func stemming(word: String, stem: String) {
        #expect(TextMatching.stem(word) == stem)
    }

    @Test func editDistanceCountsAdjacentTranspositionAsOne() {
        let d = { (a: String, b: String) in TextMatching.editDistance(Array(a.utf8), Array(b.utf8), limit: 3) }
        #expect(d("hart", "heart") == 1)
        #expect(d("haert", "heart") == 1)
        #expect(d("fire", "fire") == 0)
        #expect(d("abcd", "wxyz") == 4 || d("abcd", "wxyz") > 3)
        #expect(TextMatching.editDistance(Array("a".utf8), Array("abcde".utf8), limit: 1) == 2)
    }

    @Test func fuzzyScoreRewardsWordStartsAndRuns() {
        let s = { (n: String, h: String) in TextMatching.fuzzyScore(Array(n.utf8), Array(h.utf8)) }
        #expect(s("tup", "thumbs_up") != nil)
        #expect(s("xyz", "thumbs_up") == nil)
        #expect(s("thu", "thumbs_up")! > s("tbu", "thumbs_up")!)
    }
}
