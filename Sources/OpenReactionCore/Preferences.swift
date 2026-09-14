/// Apps where OpenReaction stays inactive. Defaults cover apps that already
/// expand `:shortcodes:` themselves, and terminals where `:` starts commands
/// (`:wq` in vim) and Return must never be intercepted. User overrides are
/// stored as differences so default-list updates still reach existing users.
public struct AppExclusions: Codable, Equatable, Sendable {
    public static let defaultBundleIdentifiers: Set<String> = [
        // Native shortcode pickers
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "Mattermost.Desktop",
        "org.zulip.zulip-electron",
        "im.riot.app",
        "ru.keepcoder.Telegram",
        "com.linear",
        "notion.id",
        "com.github.GitHubClient",
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        // OpenReaction itself is deliberately not listed: onboarding's
        // practice field relies on the picker working in its own window.
    ]

    public private(set) var added: Set<String>
    public private(set) var removed: Set<String>

    public init(added: Set<String> = [], removed: Set<String> = []) {
        self.added = added
        self.removed = removed
    }

    public func isExcluded(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        if added.contains(bundleIdentifier) { return true }
        return Self.defaultBundleIdentifiers.contains(bundleIdentifier) && !removed.contains(bundleIdentifier)
    }

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
}
