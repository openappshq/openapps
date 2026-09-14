import Foundation

/// Emoji names read from the running system's CoreEmoji resources.
///
/// These are plain property-list files inside a private framework's resource
/// directory. OpenReaction only reads them as data (no private API is linked
/// or called), never copies them, and treats every file as optional: the
/// layout differs across macOS releases and may change without notice.
public struct AppleEmojiData: Equatable, Sendable {
    /// The `.lproj` whose names are used for display, e.g. `de` or `en_GB`.
    public let localization: String
    /// Emoji string → localized display name.
    public let names: [String: String]
    /// Emoji string → English name; used for derived shortcodes.
    public let englishNames: [String: String]

    public init(localization: String, names: [String: String], englishNames: [String: String]) {
        self.localization = localization
        self.names = names
        self.englishNames = englishNames
    }

    public static let defaultRoot = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CoreEmoji.framework/Resources")

    /// Returns nil when the resources are missing or unreadable.
    public static func load(
        root: URL = defaultRoot,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppleEmojiData? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: root.path) else { return nil }
        let available = contents
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .filter { fileManager.fileExists(atPath: namesURL(root: root, localization: $0).path) }
        guard !available.isEmpty else { return nil }

        let english = available.contains("en") ? readNames(namesURL(root: root, localization: "en")) : nil
        let localization = resolveLocalization(preferred: preferredLanguages, available: available) ?? "en"
        let localized = localization == "en" ? english : readNames(namesURL(root: root, localization: localization))

        guard let names = localized ?? english else { return nil }
        return AppleEmojiData(
            localization: localized == nil ? "en" : localization,
            names: names,
            englishNames: english ?? [:]
        )
    }

    /// Picks the best `.lproj` for the user's preferred languages, e.g.
    /// `en-US` → `en`, `pt-BR` → `pt_BR`, `zh-Hant-HK` → `zh_HK`, `zh-Hans` → `zh_CN`.
    public static func resolveLocalization(preferred: [String], available: [String]) -> String? {
        let availableSet = Set(available)
        for language in preferred {
            let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let code = parts.first?.lowercased() else { continue }
            let script = parts.dropFirst().first { $0.count == 4 }
            let region = parts.dropFirst().first { $0.count == 2 || $0.count == 3 && Int($0) != nil }?.uppercased()

            var candidates: [String] = []
            if let script, let region { candidates.append("\(code)_\(script)_\(region)") }
            if let region { candidates.append("\(code)_\(region)") }
            if let script { candidates.append("\(code)_\(script)") }
            if code == "zh" {
                if region == "HK" || region == "MO" { candidates.append("zh_HK") }
                candidates.append(script == "Hant" || region == "TW" ? "zh_TW" : "zh_CN")
            }
            if code == "es", region != nil, region != "ES" { candidates.append("es_419") }
            if code == "pt" { candidates.append(region == nil || region == "BR" ? "pt_BR" : "pt_PT") }
            candidates.append(code)

            if let match = candidates.first(where: availableSet.contains) {
                return match
            }
        }
        return availableSet.contains("en") ? "en" : nil
    }

    private static func namesURL(root: URL, localization: String) -> URL {
        root.appendingPathComponent("\(localization).lproj/AppleName.strings")
    }

    private static func readNames(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        var names: [String: String] = [:]
        names.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            guard !key.isEmpty, let name = value as? String, !name.isEmpty else { continue }
            names[key] = name
        }
        return names.isEmpty ? nil : names
    }
}
