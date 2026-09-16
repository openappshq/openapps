import Foundation

/// Plain-text state for bug reports, copied only on request and only to
/// the pasteboard. The app fills the snapshot; the text is made here so a
/// test can pin its shape.
public struct DiagnosticsSnapshot: Sendable {
    public var appVersion: String
    public var loginStatus: String
    public var licensing: String
    public var displays: [DisplayInfo]
    public var panelSettings: PanelSettings
    public var hostDisplay: HostDisplay
    public var direction: PanelDirection
    public var width: PanelWidth
    public var hotkey: Hotkey?
    public var hotkeyProblem: String?
    public var shuffle: ShuffleInterval
    public var favoritesOnly: Bool
    public var sameOnAllDisplays: Bool
    public var favoritesCount: Int
    public var applied: [String: Wallpaper]
    public var lastApplied: Date?

    public init(
        appVersion: String, loginStatus: String, licensing: String, displays: [DisplayInfo], panelSettings: PanelSettings,
        hostDisplay: HostDisplay, direction: PanelDirection, width: PanelWidth, hotkey: Hotkey?, hotkeyProblem: String?,
        shuffle: ShuffleInterval, favoritesOnly: Bool, sameOnAllDisplays: Bool, favoritesCount: Int,
        applied: [String: Wallpaper], lastApplied: Date?
    ) {
        self.appVersion = appVersion
        self.loginStatus = loginStatus
        self.licensing = licensing
        self.displays = displays
        self.panelSettings = panelSettings
        self.hostDisplay = hostDisplay
        self.direction = direction
        self.width = width
        self.hotkey = hotkey
        self.hotkeyProblem = hotkeyProblem
        self.shuffle = shuffle
        self.favoritesOnly = favoritesOnly
        self.sameOnAllDisplays = sameOnAllDisplays
        self.favoritesCount = favoritesCount
        self.applied = applied
        self.lastApplied = lastApplied
    }

    public func text(generatedAt date: Date = Date()) -> String {
        var lines = [
            "macPaper \(appVersion)",
            "Generated: \(Self.dateFormatter.string(from: date))",
            "Open at login: \(loginStatus)",
            "Licensing: \(licensing)",
            "",
            "Displays:",
        ]
        if displays.isEmpty { lines.append("- none") }
        for display in displays {
            var parts = ["\(display.name) (\(display.id))", "\(Int(display.pointSize.width))×\(Int(display.pointSize.height)) pt @\(Self.number(display.scale))x", "\(display.pixelSize.width)×\(display.pixelSize.height) px"]
            if let notch = display.notchWidth { parts.append("notch \(Int(notch)) pt") }
            if display.isMain { parts.append("main") }
            lines.append("- " + parts.joined(separator: " · "))
        }
        lines.append("")
        lines.append("Notch panel: \(panelSettings.isEnabled ? "on" : "off") · host \(hostDisplay.rawValue) · opens on \(panelSettings.trigger.rawValue) · \(direction.rawValue) · \(width.rawValue) · hide in fullscreen \(panelSettings.hideInFullscreen ? "on" : "off")")
        lines.append("Hotkey: \(hotkey?.displayString ?? "none")" + (hotkeyProblem.map { " (\($0))" } ?? ""))
        lines.append("Shuffle: \(shuffle.rawValue) · favorites only \(favoritesOnly ? "on" : "off") · same on all displays \(sameOnAllDisplays ? "on" : "off")")
        lines.append("Favorites: \(favoritesCount)")
        lines.append("Last applied: \(lastApplied.map { Self.dateFormatter.string(from: $0) } ?? "never")")
        lines.append("")
        lines.append("Applied:")
        if applied.isEmpty { lines.append("- nothing yet") }
        for (display, wallpaper) in applied.sorted(by: { $0.key < $1.key }) {
            let json = (try? wallpaper.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            lines.append("- \(display): \(json)")
        }
        return lines.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
