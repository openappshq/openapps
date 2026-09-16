/// Apps where OpenReaction stays inactive. Defaults cover apps that already
/// expand `:shortcodes:` themselves, and terminals where `:` starts commands
/// (`:wq` in vim) and Return must never be intercepted. User overrides are
/// stored as differences from the default list, so default-list updates still
/// reach existing users: `added` are extra exclusions, `removed` are defaults
/// the user switched back on.
public struct AppExclusions: Codable, Equatable, Sendable {
    /// Why an app is excluded by default.
    public enum DefaultReason: String, Codable, CaseIterable, Sendable {
        case ownShortcodes
        case terminal

        public var summary: String {
            switch self {
            case .ownShortcodes: "Has its own emoji shortcodes"
            case .terminal: "Terminal"
            }
        }
    }

    /// One app in the list, default or user-added.
    public struct Entry: Hashable, Sendable {
        public let bundleIdentifier: String
        /// nil for apps the user added.
        public let defaultReason: DefaultReason?
        /// Whether OpenReaction currently stays off in this app.
        public let isExcluded: Bool

        public var isDefault: Bool { defaultReason != nil }
    }

    /// Built-in exclusions, in display order.
    public static let defaults: [(bundleIdentifier: String, reason: DefaultReason)] = [
        // Native shortcode pickers
        ("com.tinyspeck.slackmacgap", .ownShortcodes),
        ("com.hnc.Discord", .ownShortcodes),
        ("com.hnc.DiscordPTB", .ownShortcodes),
        ("com.hnc.DiscordCanary", .ownShortcodes),
        ("com.microsoft.teams2", .ownShortcodes),
        ("com.microsoft.teams", .ownShortcodes),
        ("Mattermost.Desktop", .ownShortcodes),
        ("org.zulip.zulip-electron", .ownShortcodes),
        ("im.riot.app", .ownShortcodes),
        ("ru.keepcoder.Telegram", .ownShortcodes),
        ("com.linear", .ownShortcodes),
        ("notion.id", .ownShortcodes),
        ("com.github.GitHubClient", .ownShortcodes),
        // Terminals
        ("com.apple.Terminal", .terminal),
        ("com.googlecode.iterm2", .terminal),
        ("com.mitchellh.ghostty", .terminal),
        ("dev.warp.Warp-Stable", .terminal),
        ("com.github.wez.wezterm", .terminal),
        ("org.alacritty", .terminal),
        ("net.kovidgoyal.kitty", .terminal),
        // OpenReaction itself is deliberately not listed: onboarding's
        // practice field relies on the picker working in its own window.
    ]

    public static let defaultBundleIdentifiers: Set<String> = Set(defaults.map(\.bundleIdentifier))

    private static let defaultReasons: [String: DefaultReason] = Dictionary(
        defaults.map { ($0.bundleIdentifier, $0.reason) }, uniquingKeysWith: { first, _ in first }
    )

    public static func defaultReason(for bundleIdentifier: String) -> DefaultReason? {
        defaultReasons[bundleIdentifier]
    }

    public private(set) var added: Set<String>
    public private(set) var removed: Set<String>

    public init(added: Set<String> = [], removed: Set<String> = []) {
        self.added = added
        self.removed = removed
        normalize()
    }

    /// Decoding normalizes against the current defaults: an app that became
    /// a default is no longer "added", and a removal of something that is no
    /// longer a default is dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        added = try container.decodeIfPresent(Set<String>.self, forKey: .added) ?? []
        removed = try container.decodeIfPresent(Set<String>.self, forKey: .removed) ?? []
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case added, removed
    }

    public func isExcluded(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        if added.contains(bundleIdentifier) { return true }
        return Self.defaultBundleIdentifiers.contains(bundleIdentifier) && !removed.contains(bundleIdentifier)
    }

    /// Every bundle id where OpenReaction currently stays off.
    public var effectiveBundleIdentifiers: Set<String> {
        Self.defaultBundleIdentifiers.subtracting(removed).union(added)
    }

    /// Defaults first in their built-in order (including ones switched back
    /// on), then user additions sorted by bundle id.
    public var entries: [Entry] {
        let defaults = Self.defaults.map { item in
            Entry(bundleIdentifier: item.bundleIdentifier, defaultReason: item.reason, isExcluded: !removed.contains(item.bundleIdentifier))
        }
        let extras = added.sorted { $0.lowercased() < $1.lowercased() }.map {
            Entry(bundleIdentifier: $0, defaultReason: nil, isExcluded: true)
        }
        return defaults + extras
    }

    public var hasUserChanges: Bool { !added.isEmpty || !removed.isEmpty }

    public mutating func setExcluded(_ excluded: Bool, bundleIdentifier: String) {
        let isDefault = Self.defaultBundleIdentifiers.contains(bundleIdentifier)
        if excluded {
            removed.remove(bundleIdentifier)
            if !isDefault { added.insert(bundleIdentifier) }
        } else {
            added.remove(bundleIdentifier)
            if isDefault { removed.insert(bundleIdentifier) }
        }
    }

    /// Excludes the given apps. Empty ids are ignored; defaults that were
    /// switched off are switched back on rather than duplicated.
    public mutating func add(_ bundleIdentifiers: some Sequence<String>) {
        for bundleIdentifier in bundleIdentifiers where !bundleIdentifier.isEmpty {
            setExcluded(true, bundleIdentifier: bundleIdentifier)
        }
    }

    /// Removes a user-added app from the list. Defaults cannot be removed,
    /// only switched off with `setExcluded`.
    public mutating func remove(_ bundleIdentifier: String) {
        added.remove(bundleIdentifier)
    }

    public mutating func restoreDefaults() {
        added.removeAll()
        removed.removeAll()
    }

    private mutating func normalize() {
        added.subtract(Self.defaultBundleIdentifiers)
        added.remove("")
        removed.formIntersection(Self.defaultBundleIdentifiers)
    }
}

/// Apps where the typed-replacement fallback is turned off. The fallback lets
/// OpenReaction insert into fields Accessibility cannot read back (Chromium and
/// Electron web views) by trusting the tail it saw typed, so it is on by
/// default everywhere. Only the apps the user switched off are stored, as a
/// difference from that default — the same way `AppExclusions` stores its
/// differences — so the default staying "on for every app" needs nothing on
/// disk.
public struct TypedReplacementSettings: Codable, Equatable, Sendable {
    public private(set) var disabled: Set<String>

    public init(disabled: Set<String> = []) {
        self.disabled = disabled
        normalize()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabled = try container.decodeIfPresent(Set<String>.self, forKey: .disabled) ?? []
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case disabled
    }

    /// True unless the app was switched off. An unknown app (no bundle id)
    /// keeps the default, on.
    public func isEnabled(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !disabled.contains(bundleIdentifier)
    }

    public var hasUserChanges: Bool { !disabled.isEmpty }

    /// Apps switched off, sorted by bundle id.
    public var disabledBundleIdentifiers: [String] {
        disabled.sorted { $0.lowercased() < $1.lowercased() }
    }

    public mutating func setEnabled(_ enabled: Bool, bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return }
        if enabled {
            disabled.remove(bundleIdentifier)
        } else {
            disabled.insert(bundleIdentifier)
        }
    }

    /// Switches the given apps off. Empty ids are ignored.
    public mutating func disable(_ bundleIdentifiers: some Sequence<String>) {
        for bundleIdentifier in bundleIdentifiers where !bundleIdentifier.isEmpty {
            disabled.insert(bundleIdentifier)
        }
    }

    public mutating func restoreDefaults() {
        disabled.removeAll()
    }

    private mutating func normalize() {
        disabled.remove("")
    }
}
