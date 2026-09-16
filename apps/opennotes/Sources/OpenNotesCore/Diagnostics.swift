import Foundation

/// Plain-text state for bug reports (Settings → About → Copy Diagnostics).
/// Built from the live objects by the app, rendered here so the text is
/// tested. Never contains a note's text.
nonisolated public struct DiagnosticsSnapshot: Hashable, Sendable {
    public var appVersion: String
    public var macOSVersion: String
    public var loginStatus: String
    /// The build's licensing line ("off (source build)", or the state).
    public var licensing: String
    public var readOnly: Bool
    public var side: DeckSide
    public var display: DeckDisplay
    public var hotkey: Hotkey?
    public var hotkeyProblem: String?
    public var folder: String
    public var folderIsMissing: Bool
    /// The storage choice ("On this Mac", "iCloud Drive", "Other folder") and,
    /// for a folder in iCloud, the sync-relevant state.
    public var storage: String
    public var watching: Bool
    public var activeCount: Int
    public var archivedCount: Int
    public var unsavedCount: Int
    public var defaultFace: NoteFace
    public var defaultColor: NoteColor
    public var autoArchiveDays: Int
    public var deckState: String
    public var hostedDisplays: [String]

    public init(appVersion: String, macOSVersion: String, loginStatus: String, licensing: String, readOnly: Bool, side: DeckSide, display: DeckDisplay, hotkey: Hotkey?, hotkeyProblem: String?, folder: String, folderIsMissing: Bool, storage: String = "On this Mac", watching: Bool, activeCount: Int, archivedCount: Int, unsavedCount: Int, defaultFace: NoteFace, defaultColor: NoteColor, autoArchiveDays: Int, deckState: String, hostedDisplays: [String]) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.loginStatus = loginStatus
        self.licensing = licensing
        self.readOnly = readOnly
        self.side = side
        self.display = display
        self.hotkey = hotkey
        self.hotkeyProblem = hotkeyProblem
        self.folder = folder
        self.folderIsMissing = folderIsMissing
        self.storage = storage
        self.watching = watching
        self.activeCount = activeCount
        self.archivedCount = archivedCount
        self.unsavedCount = unsavedCount
        self.defaultFace = defaultFace
        self.defaultColor = defaultColor
        self.autoArchiveDays = autoArchiveDays
        self.deckState = deckState
        self.hostedDisplays = hostedDisplays
    }

    public func text() -> String {
        var lines: [String] = []
        lines.append("OpenNotes \(appVersion) · macOS \(macOSVersion)")
        lines.append("Open at login: \(loginStatus)")
        lines.append("Licensing: \(licensing)" + (readOnly ? " · read-only" : ""))
        lines.append("Deck: \(side.rawValue) edge · \(display.title.lowercased()) · \(deckState)")
        lines.append("Displays hosting a deck: " + (hostedDisplays.isEmpty ? "none" : hostedDisplays.joined(separator: ", ")))
        var hotkeyLine = "Hotkey: " + (hotkey?.displayString ?? "none")
        if let hotkeyProblem { hotkeyLine += " (\(hotkeyProblem))" }
        lines.append(hotkeyLine)
        lines.append("Folder: \(folder)" + (folderIsMissing ? " (missing)" : "") + " · \(storage) · watcher \(watching ? "on" : "off")")
        lines.append("Notes: \(activeCount) active · \(archivedCount) archived · \(unsavedCount) unsaved")
        lines.append("Defaults: \(defaultFace.title) · \(defaultColor.title) · auto-archive \(AutoArchive.title(days: autoArchiveDays).lowercased())")
        return lines.joined(separator: "\n")
    }
}
