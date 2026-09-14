import Foundation

public struct EmojiEntry: Hashable, Sendable {
    public let emoji: String
    public let description: String
    public let category: String
    /// Shortcodes without colons. The first one is the primary shortcode.
    public let aliases: [String]
    public let tags: [String]
    /// First iOS version whose emoji font includes this emoji, e.g. "17.4".
    public let iosVersion: String?

    public init(emoji: String, description: String, category: String, aliases: [String], tags: [String], iosVersion: String? = nil) {
        self.emoji = emoji
        self.description = description
        self.category = category
        self.aliases = aliases
        self.tags = tags
        self.iosVersion = iosVersion
    }

    public var primaryShortcode: String { aliases.first ?? "" }
}

/// The emoji set with shortcode lookup, loaded from gemoji's `emoji.json` format.
public struct EmojiDatabase: Sendable {
    public let entries: [EmojiEntry]
    private let indexByAlias: [String: Int]

    public init(entries: [EmojiEntry]) {
        self.entries = entries
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() {
            for alias in entry.aliases where index[alias] == nil {
                index[alias] = position
            }
        }
        indexByAlias = index
    }

    public init(jsonData: Data) throws {
        struct Record: Decodable {
            let emoji: String?
            let description: String?
            let category: String?
            let aliases: [String]
            let tags: [String]?
            let ios_version: String?
        }
        let records = try JSONDecoder().decode([Record].self, from: jsonData)
        self.init(entries: records.compactMap { record in
            guard let emoji = record.emoji, !record.aliases.isEmpty else { return nil }
            return EmojiEntry(
                emoji: emoji,
                description: record.description ?? "",
                category: record.category ?? "",
                aliases: record.aliases.map { $0.lowercased() },
                tags: (record.tags ?? []).map { $0.lowercased() },
                iosVersion: record.ios_version
            )
        })
    }

    /// Keeps only emoji for which `isRenderable` returns true. Used to hide
    /// emoji newer than the running system's emoji font, which would show as
    /// empty boxes in the picker and in the target app.
    public func filtered(_ isRenderable: (EmojiEntry) -> Bool) -> EmojiDatabase {
        EmojiDatabase(entries: entries.filter(isRenderable))
    }

    /// Fallback check when the emoji font cannot be inspected: compares the
    /// entry's iOS introduction version with the iOS release that shipped the
    /// same emoji font as the given macOS version.
    public static func isSupported(_ entry: EmojiEntry, onMacOS version: OperatingSystemVersion) -> Bool {
        guard let iosVersion = entry.iosVersion else { return true }
        let parts = iosVersion.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        let minor = parts.count > 1 ? parts[1] : 0
        let equivalent = iosEquivalent(ofMacOS: version)
        return (major, minor) <= (equivalent.major, equivalent.minor)
    }

    /// macOS 14 and 15 track iOS 17 and 18 point releases; from 26 the numbers match.
    static func iosEquivalent(ofMacOS version: OperatingSystemVersion) -> (major: Int, minor: Int) {
        version.majorVersion >= 26
            ? (version.majorVersion, version.minorVersion)
            : (version.majorVersion + 3, version.minorVersion)
    }

    /// Exact shortcode lookup, case-insensitive, without colons.
    public func entry(forShortcode shortcode: String) -> EmojiEntry? {
        indexByAlias[shortcode.lowercased()].map { entries[$0] }
    }

    /// Loads the bundled dataset. An app bundle's `Contents/Resources/emoji.json`
    /// wins, so the packaged app never depends on SwiftPM's build-directory bundle.
    public static func bundled() throws -> EmojiDatabase {
        if let url = Bundle.main.url(forResource: "emoji", withExtension: "json") {
            return try EmojiDatabase(jsonData: Data(contentsOf: url))
        }
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try EmojiDatabase(jsonData: Data(contentsOf: url))
    }
}
