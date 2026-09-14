import Foundation
import OpenReactionCore
import Testing

@Suite("Preferences")
struct PreferencesTests {
    @Test func defaultsAreExcluded() {
        let exclusions = AppExclusions()
        #expect(exclusions.isExcluded("com.tinyspeck.slackmacgap"))
        #expect(exclusions.isExcluded("com.apple.Terminal"))
        #expect(!exclusions.isExcluded("com.apple.TextEdit"))
        #expect(!exclusions.isExcluded(nil))
        // The onboarding practice field types into OpenReaction's own window.
        #expect(!exclusions.isExcluded("com.openappshq.openreaction"))
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

    @Test func frecencyFavorsFrequentAndRecentUse() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 24 * 60 * 60
        var frecency = Frecency(halfLifeDays: 7)
        frecency.record("old", now: start)
        frecency.record("old", now: start)
        frecency.record("old", now: start)
        frecency.record("new", now: start.addingTimeInterval(21 * day))

        let now = start.addingTimeInterval(21 * day)
        // Three uses three half-lives ago are worth 3/8; one use today is worth 1.
        #expect(abs(frecency.score("old", now: now) - 0.375) < 0.0001)
        #expect(frecency.score("new", now: now) == 1)
        #expect(frecency.score("never", now: now) == 0)
    }

    @Test func frecencyStoresOnlyTheDayOfUse() throws {
        var frecency = Frecency()
        frecency.record("🎉", now: Date(timeIntervalSince1970: 86_400 * 100 + 12_345))
        let json = String(decoding: try JSONEncoder().encode(frecency), as: UTF8.self)
        #expect(json.contains("\"day\":100"))
        #expect(!json.contains("12345"))
        // Same score at any time of that day, and nothing else is recorded.
        #expect(frecency.score("🎉", now: Date(timeIntervalSince1970: 86_400 * 100)) == 1)
        #expect(frecency.score("🎉", now: Date(timeIntervalSince1970: 86_400 * 101 - 1)) == 1)
    }

    @Test func legacyFrecencyWithTimestampsMigratesToDays() throws {
        let legacy = """
        {"halfLife":1209600,"limit":200,"entries":{"🎉":{"value":2.5,"updated":8640012.5}}}
        """
        let migrated = try JSONDecoder().decode(Frecency.self, from: Data(legacy.utf8))
        #expect(migrated.halfLifeDays == 14)
        #expect(!migrated.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        #expect(json.contains("\"day\":"))
        #expect(!json.contains("updated"))
        #expect(!json.contains("8640012"))
    }

    @Test func frecencyCanBeCleared() {
        var frecency = Frecency()
        frecency.record("🎉")
        #expect(!frecency.isEmpty)
        frecency.removeAll()
        #expect(frecency.isEmpty)
        #expect(frecency.scores().isEmpty)
    }

    @Test func frecencyDropsWeakestBeyondLimit() {
        let now = Date(timeIntervalSince1970: 0)
        var frecency = Frecency(limit: 2)
        frecency.record("a", now: now)
        frecency.record("a", now: now)
        frecency.record("b", now: now)
        frecency.record("c", now: now)
        let scores = frecency.scores(now: now)
        #expect(scores.count == 2)
        #expect(scores["a"] == 2)
    }

    @Test func frecencyRoundTripsThroughCodable() throws {
        var frecency = Frecency()
        frecency.record("🎉", now: Date(timeIntervalSince1970: 5))
        let decoded = try JSONDecoder().decode(Frecency.self, from: JSONEncoder().encode(frecency))
        #expect(decoded == frecency)
    }
}
