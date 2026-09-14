import Foundation
@testable import OpenReactionCore
import Testing

@Suite("Emoji catalog")
struct EmojiCatalogTests {
    @Test func bundledGemojiLoads() throws {
        let gemoji = try EmojiDatabase.bundled()
        #expect(gemoji.entries.count > 1800)
        #expect(gemoji.entry(forShortcode: "TADA")?.emoji == "🎉")
    }

    @Test func systemNamesDefineTheSet() {
        let catalog = Fixtures.catalog()
        #expect(catalog.source == .macOS(localization: "en"))
        #expect(catalog.records.count == Fixtures.englishNames.count)
        // A gemoji emoji the system data does not list is left out.
        #expect(catalog.record(forShortcode: "rocket") == nil)
    }

    @Test func gemojiContributesAliasesAndTags() throws {
        let catalog = Fixtures.catalog()
        let tada = try #require(catalog.record(forShortcode: "tada"))
        #expect(tada.name == "party popper")
        #expect(tada.shortcodes.first == "tada")
        #expect(tada.shortcodes.contains("party_popper"))
        #expect(tada.keywords.contains("hooray"))
        #expect(catalog.record(forShortcode: "+1")?.emoji == "👍")
    }

    @Test func systemOnlyEmojiGetDerivedShortcodes() throws {
        let record = try #require(Fixtures.catalog().record(forShortcode: "face_with_bags_under_eyes"))
        #expect(record.emoji == "🫩")
        #expect(record.shortcodes == ["face_with_bags_under_eyes"])
    }

    @Test func localizedNamesDisplayAndSearch() throws {
        let localized = Fixtures.englishNames.merging(["🎉": "Partyknaller"]) { _, new in new }
        let catalog = Fixtures.catalog(localized: localized)
        #expect(catalog.source == .macOS(localization: "de"))
        let tada = try #require(catalog.record(forShortcode: "tada"))
        #expect(tada.name == "Partyknaller")
        #expect(tada.shortcodes.contains("party_popper"))
        #expect(EmojiSearch(catalog: catalog).matches(for: "partyk").first?.record.emoji == "🎉")
    }

    @Test func unsupportedEmojiAreHiddenAndCounted() {
        let catalog = Fixtures.catalog(supported: { $0 != "🫩" })
        #expect(catalog.unsupportedCount == 1)
        #expect(catalog.record(forShortcode: "face_with_bags_under_eyes") == nil)
        #expect(!EmojiSearch(catalog: catalog).matches(for: "bags").contains { $0.record.emoji == "🫩" })
    }

    @Test func fallsBackToGemojiWithoutSystemData() {
        let catalog = Fixtures.catalog(names: nil)
        #expect(catalog.source == .gemoji)
        #expect(catalog.records.count == Fixtures.gemoji.entries.count)
        #expect(catalog.record(forShortcode: "rocket")?.name == "rocket")
    }

    @Test func variationSelectorDifferencesStillMatch() throws {
        // System key without U+FE0F, gemoji with it: keep the emoji-presentation form.
        let catalog = Fixtures.catalog(names: ["❤": "red heart"])
        let heart = try #require(catalog.record(forShortcode: "heart"))
        #expect(heart.emoji == "❤️")
    }

    @Test(arguments: [
        ("thumbs up", "thumbs_up"),
        ("flag: Côte d’Ivoire", "flag_cote_d_ivoire"),
        ("keycap: *", "keycap"),
        ("A button (blood type)", "a_button_blood_type"),
    ])
    func derivedShortcodes(name: String, shortcode: String) {
        #expect(EmojiCatalog.derivedShortcode(name) == shortcode)
    }

    @Test func providerMapsRecordsToSuggestions() {
        let provider = EmojiSuggestionProvider(catalog: Fixtures.catalog())
        #expect(provider.exactMatch(for: "Tada")?.payload == .text("🎉"))
        #expect(provider.exactMatch(for: "nope_nope") == nil)
        let first = provider.suggestions(for: "tad", usage: [:], limit: 3).first
        #expect(first?.title == "tada")
        #expect(first?.subtitle == "party popper")
    }

    @Test func versionFallbackHidesEmojiNewerThanTheSystem() {
        func entry(_ version: String?) -> EmojiEntry {
            EmojiEntry(emoji: "x", description: "", category: "", aliases: ["x"], tags: [], iosVersion: version)
        }
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let sonoma4 = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        #expect(EmojiDatabase.isSupported(entry("17.0"), onMacOS: sonoma))
        #expect(!EmojiDatabase.isSupported(entry("17.4"), onMacOS: sonoma))
        #expect(EmojiDatabase.isSupported(entry("17.4"), onMacOS: sonoma4))
        #expect(EmojiDatabase.isSupported(entry("18.4"), onMacOS: tahoe))
        #expect(EmojiDatabase.isSupported(entry(nil), onMacOS: sonoma))
    }
}

@Suite("System emoji data loading")
struct AppleEmojiDataTests {
    private func makeRoot(_ files: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoreEmojiFixture-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let dictionary = contents as? [String: String] {
                try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: url)
            } else if let raw = contents as? Data {
                try raw.write(to: url)
            }
        }
        return root
    }

    @Test func loadsLocalizedAndEnglishNames() throws {
        let root = try makeRoot([
            "en.lproj/AppleName.strings": ["🎉": "party popper"],
            "de.lproj/AppleName.strings": ["🎉": "Partyknaller"],
        ])
        let data = try #require(AppleEmojiData.load(root: root, preferredLanguages: ["de-DE", "en"]))
        #expect(data.localization == "de")
        #expect(data.names["🎉"] == "Partyknaller")
        #expect(data.englishNames["🎉"] == "party popper")
    }

    @Test func textFormatStringsFilesParse() throws {
        let text = Data(#""🎉" = "party popper";"#.utf8)
        let root = try makeRoot(["en.lproj/AppleName.strings": text])
        #expect(AppleEmojiData.load(root: root, preferredLanguages: ["en"])?.names["🎉"] == "party popper")
    }

    @Test func missingOrCorruptDataReturnsNil() throws {
        #expect(AppleEmojiData.load(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) == nil)
        let corrupt = try makeRoot(["en.lproj/AppleName.strings": Data([0xFF, 0x00, 0x13])])
        #expect(AppleEmojiData.load(root: corrupt, preferredLanguages: ["en"]) == nil)
    }

    @Test func unreadableLocalizationFallsBackToEnglish() throws {
        let root = try makeRoot([
            "en.lproj/AppleName.strings": ["🎉": "party popper"],
            "fr.lproj/AppleName.strings": Data([0x00]),
        ])
        let data = try #require(AppleEmojiData.load(root: root, preferredLanguages: ["fr"]))
        #expect(data.localization == "en")
        #expect(data.names["🎉"] == "party popper")
    }

    @Test(arguments: [
        (["en-US"], "en"),
        (["en-GB"], "en_GB"),
        (["pt-BR"], "pt_BR"),
        (["pt-AO"], "pt_PT"),
        (["es-MX"], "es_419"),
        (["zh-Hans-CN"], "zh_CN"),
        (["zh-Hant-TW"], "zh_TW"),
        (["zh-Hant-HK"], "zh_HK"),
        (["pt"], "pt_BR"),
        (["xx", "de-AT"], "de"),
        (["xx"], "en"),
    ])
    func localizationResolution(preferred: [String], expected: String) {
        let available = ["en", "en_GB", "de", "pt_BR", "pt_PT", "es", "es_419", "zh_CN", "zh_TW", "zh_HK"]
        #expect(AppleEmojiData.resolveLocalization(preferred: preferred, available: available) == expected)
    }
}
