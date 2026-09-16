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

    @Test func entriesListEveryDefaultThenUserAdditions() {
        var exclusions = AppExclusions()
        exclusions.add(["com.apple.TextEdit", "com.apple.Notes"])
        exclusions.setExcluded(false, bundleIdentifier: "com.apple.Terminal")
        let entries = exclusions.entries
        #expect(entries.count == AppExclusions.defaults.count + 2)
        #expect(entries.prefix(AppExclusions.defaults.count).map(\.bundleIdentifier) == AppExclusions.defaults.map(\.bundleIdentifier))
        #expect(entries.suffix(2).map(\.bundleIdentifier) == ["com.apple.Notes", "com.apple.TextEdit"])
        // A default that was switched off stays listed, marked as not excluded.
        let terminal = entries.first { $0.bundleIdentifier == "com.apple.Terminal" }
        #expect(terminal?.isDefault == true)
        #expect(terminal?.defaultReason == .terminal)
        #expect(terminal?.isExcluded == false)
        let slack = entries.first { $0.bundleIdentifier == "com.tinyspeck.slackmacgap" }
        #expect(slack?.defaultReason == .ownShortcodes)
        #expect(slack?.isExcluded == true)
        #expect(entries.last?.isDefault == false)
        #expect(entries.last?.isExcluded == true)
    }

    @Test func addDedupesIgnoresEmptyAndRevivesDefaults() {
        var exclusions = AppExclusions()
        exclusions.setExcluded(false, bundleIdentifier: "com.apple.Terminal")
        exclusions.add(["com.apple.TextEdit", "", "com.apple.TextEdit", "com.apple.Terminal"])
        #expect(exclusions.added == ["com.apple.TextEdit"])
        #expect(exclusions.removed.isEmpty)
        #expect(exclusions.isExcluded("com.apple.Terminal"))
    }

    @Test func removeOnlyAffectsUserAdditions() {
        var exclusions = AppExclusions()
        exclusions.add(["com.apple.TextEdit"])
        exclusions.remove("com.apple.TextEdit")
        exclusions.remove("com.apple.Terminal")
        #expect(!exclusions.isExcluded("com.apple.TextEdit"))
        #expect(exclusions.isExcluded("com.apple.Terminal"))
        #expect(exclusions == AppExclusions())
    }

    @Test func restoreDefaultsClearsEveryChange() {
        var exclusions = AppExclusions()
        exclusions.add(["com.apple.TextEdit"])
        exclusions.setExcluded(false, bundleIdentifier: "com.apple.Terminal")
        #expect(exclusions.hasUserChanges)
        exclusions.restoreDefaults()
        #expect(!exclusions.hasUserChanges)
        #expect(exclusions.effectiveBundleIdentifiers == AppExclusions.defaultBundleIdentifiers)
    }

    @Test func effectiveSetReflectsDifferences() {
        var exclusions = AppExclusions()
        exclusions.add(["com.apple.TextEdit"])
        exclusions.setExcluded(false, bundleIdentifier: "com.apple.Terminal")
        let effective = exclusions.effectiveBundleIdentifiers
        #expect(effective.contains("com.apple.TextEdit"))
        #expect(!effective.contains("com.apple.Terminal"))
        #expect(effective.count == AppExclusions.defaultBundleIdentifiers.count)
    }

    @Test func exclusionsRoundTripAsDifferences() throws {
        var exclusions = AppExclusions()
        exclusions.add(["com.apple.TextEdit"])
        exclusions.setExcluded(false, bundleIdentifier: "com.apple.Terminal")
        let data = try JSONEncoder().encode(exclusions)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("com.apple.TextEdit"))
        #expect(json.contains("com.apple.Terminal"))
        // Defaults themselves are not written, so a new default list applies on load.
        #expect(!json.contains("com.tinyspeck.slackmacgap"))
        #expect(try JSONDecoder().decode(AppExclusions.self, from: data) == exclusions)
    }

    @Test func decodingNormalizesAgainstTheCurrentDefaults() throws {
        // A stored file from a version where Slack was user-added and
        // "org.example.OldTerminal" was a default the user switched off.
        let stored = """
        {"added":["com.tinyspeck.slackmacgap","com.apple.TextEdit",""],"removed":["org.example.OldTerminal","com.apple.Terminal"]}
        """
        let exclusions = try JSONDecoder().decode(AppExclusions.self, from: Data(stored.utf8))
        #expect(exclusions.added == ["com.apple.TextEdit"])
        #expect(exclusions.removed == ["com.apple.Terminal"])
        #expect(exclusions.isExcluded("com.tinyspeck.slackmacgap"))
        #expect(!exclusions.isExcluded("org.example.OldTerminal"))
        #expect(!exclusions.entries.contains { $0.bundleIdentifier == "org.example.OldTerminal" })
    }

    // MARK: Typed replacement

    @Test func typedReplacementIsOnByDefaultAndOffPerApp() {
        var settings = TypedReplacementSettings()
        #expect(settings.isEnabled("com.google.Chrome"))
        #expect(settings.isEnabled(nil)) // unknown app keeps the default, on
        settings.setEnabled(false, bundleIdentifier: "com.google.Chrome")
        #expect(!settings.isEnabled("com.google.Chrome"))
        #expect(settings.isEnabled("com.microsoft.VSCode"))
        settings.setEnabled(true, bundleIdentifier: "com.google.Chrome")
        #expect(settings == TypedReplacementSettings())
    }

    @Test func typedReplacementDisableIgnoresEmptyAndDedupes() {
        var settings = TypedReplacementSettings()
        settings.disable(["com.google.Chrome", "", "com.google.Chrome", "com.microsoft.VSCode"])
        #expect(settings.disabled == ["com.google.Chrome", "com.microsoft.VSCode"])
        #expect(settings.disabledBundleIdentifiers == ["com.google.Chrome", "com.microsoft.VSCode"])
        #expect(settings.hasUserChanges)
    }

    @Test func typedReplacementRestoreDefaultsClearsEveryChange() {
        var settings = TypedReplacementSettings()
        settings.disable(["com.google.Chrome"])
        #expect(settings.hasUserChanges)
        settings.restoreDefaults()
        #expect(!settings.hasUserChanges)
        #expect(settings.isEnabled("com.google.Chrome"))
    }

    @Test func typedReplacementRoundTripsAsDifferences() throws {
        var settings = TypedReplacementSettings()
        settings.setEnabled(false, bundleIdentifier: "com.google.Chrome")
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains("com.google.Chrome"))
        #expect(try JSONDecoder().decode(TypedReplacementSettings.self, from: data) == settings)
        // An empty payload decodes to the default (on everywhere).
        let empty = try JSONDecoder().decode(TypedReplacementSettings.self, from: Data("{}".utf8))
        #expect(empty == TypedReplacementSettings())
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
