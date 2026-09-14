import Foundation
import OpenReactionCore
import Testing

@Suite("Preferences")
struct PreferencesTests {
    @Test func recentsMoveToFrontWithoutDuplicates() {
        var recents = RecentItems(limit: 3)
        recents.record("a")
        recents.record("b")
        recents.record("a")
        #expect(recents.items == ["a", "b"])
    }

    @Test func recentsAreCapped() {
        var recents = RecentItems(limit: 2)
        ["a", "b", "c"].forEach { recents.record($0) }
        #expect(recents.items == ["c", "b"])
    }

    @Test func defaultsAreExcluded() {
        let exclusions = AppExclusions()
        #expect(exclusions.isExcluded("com.tinyspeck.slackmacgap"))
        #expect(exclusions.isExcluded("com.apple.Terminal"))
        #expect(!exclusions.isExcluded("com.apple.TextEdit"))
        #expect(!exclusions.isExcluded(nil))
    }

    @Test func userCanIncludeADefaultAndExcludeOthers() {
        var exclusions = AppExclusions()
        exclusions.setExcluded(false, bundleIdentifier: "com.tinyspeck.slackmacgap")
        exclusions.setExcluded(true, bundleIdentifier: "com.apple.TextEdit")
        #expect(!exclusions.isExcluded("com.tinyspeck.slackmacgap"))
        #expect(exclusions.isExcluded("com.apple.TextEdit"))

        exclusions.setExcluded(true, bundleIdentifier: "com.tinyspeck.slackmacgap")
        exclusions.setExcluded(false, bundleIdentifier: "com.apple.TextEdit")
        #expect(exclusions == AppExclusions())
    }

    @Test func renderabilityFilterUsesInjectedCapability() throws {
        let database = try EmojiDatabase.bundled()
        let filtered = database.filtered { $0.emoji != "🎉" }
        #expect(filtered.entries.count == database.entries.count - 1)
        #expect(filtered.entry(forShortcode: "tada") == nil)
        #expect(EmojiMatcher(database: filtered).matches(for: "tada").allSatisfy { $0.entry.emoji != "🎉" })
    }

    @Test func versionFallbackHidesEmojiNewerThanTheSystem() {
        func entry(_ version: String?) -> EmojiEntry {
            EmojiEntry(emoji: "x", description: "", category: "", aliases: ["x"], tags: [], iosVersion: version)
        }
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let sonoma4 = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        #expect(EmojiDatabase.isSupported(entry("16.4"), onMacOS: sonoma))
        #expect(EmojiDatabase.isSupported(entry("17.0"), onMacOS: sonoma))
        #expect(!EmojiDatabase.isSupported(entry("17.4"), onMacOS: sonoma))
        #expect(EmojiDatabase.isSupported(entry("17.4"), onMacOS: sonoma4))
        #expect(!EmojiDatabase.isSupported(entry("18.4"), onMacOS: sonoma4))
        #expect(EmojiDatabase.isSupported(entry("18.4"), onMacOS: tahoe))
        #expect(EmojiDatabase.isSupported(entry(nil), onMacOS: sonoma))
    }

    @Test func emojiProviderMapsMatches() throws {
        let provider = EmojiSuggestionProvider(database: try EmojiDatabase.bundled())
        #expect(provider.exactMatch(for: "Tada")?.payload == .text("🎉"))
        #expect(provider.exactMatch(for: "not_an_emoji_code") == nil)
        let first = provider.suggestions(for: "tad", recents: [], limit: 3).first
        #expect(first?.title == "tada")
        #expect(first?.preview == .glyph("🎉"))
    }
}
