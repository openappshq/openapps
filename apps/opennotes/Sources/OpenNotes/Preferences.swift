import Foundation
import Observation
import OpenNotesCore

/// The settings, saved as they change. Every key here is listed in
/// `FreshInstallDefault.Key.earlierPreferenceEvidence`; the first-run
/// flags live beside them in the same defaults domain. The notes are
/// files in the folder, never preferences.
@Observable
final class Preferences {
    enum Key {
        static let side = "deck.side"
        static let display = "deck.display"
        static let hotkey = "hotkey"
        static let folder = "notesFolder"
        static let face = "notes.face"
        static let color = "notes.color"
        static let autoArchiveDays = "notes.autoArchiveDays"
        static let hideFromScreenSharing = FreshInstallDefault.Key.hideFromScreenSharing
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// The first-run flags share the defaults domain (`FlagStore`): the
    /// welcome note's decision is kept there, beside the guide's.
    @ObservationIgnored let flags: any FlagStore
    /// An earlier launch left preferences behind (`FreshInstallDefault`),
    /// read when this is created, before the current launch writes any:
    /// the install is not fresh, and the welcome note is not for it.
    @ObservationIgnored let hadEarlierPreferences: Bool

    var side: DeckSide {
        didSet { defaults.set(side.rawValue, forKey: Key.side) }
    }
    var display: DeckDisplay {
        didSet { defaults.set(display.rawValue, forKey: Key.display) }
    }
    /// Nil is "no hotkey".
    var hotkey: Hotkey? {
        didSet {
            if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
                defaults.set(data, forKey: Key.hotkey)
            } else {
                // Stored as empty data, not removed: "no hotkey" is a choice,
                // and a choice is earlier-launch evidence.
                defaults.set(Data(), forKey: Key.hotkey)
            }
        }
    }
    /// The notes folder; the default is `~/Documents/OpenNotes`.
    var folder: URL {
        didSet { defaults.set(folder.path, forKey: Key.folder) }
    }
    /// Whether the folder is the default one (created when missing) or a
    /// chosen one (never created by the app).
    var usesDefaultFolder: Bool { defaults.string(forKey: Key.folder) == nil }
    var face: NoteFace {
        didSet { defaults.set(face.rawValue, forKey: Key.face) }
    }
    var color: NoteColor {
        didSet { defaults.set(color.rawValue, forKey: Key.color) }
    }
    /// 0 is off.
    var autoArchiveDays: Int {
        didSet { defaults.set(autoArchiveDays, forKey: Key.autoArchiveDays) }
    }
    /// The deck and All Notes ask macOS to be left out of screen captures
    /// (`ScreenSharing`; a request, not a guarantee). Turned on once on a fresh install
    /// (`applyScreenSharingDefaultIfNeeded`, `FreshInstallDefault`); any
    /// write here — the user's or the default's — records the decision, so
    /// a choice made before storage answers is never undone.
    var hideFromScreenSharing: Bool {
        didSet {
            defaults.set(hideFromScreenSharing, forKey: Key.hideFromScreenSharing)
            screenSharingDefault.markSuperseded()
        }
    }
    /// Created with the preferences, before this launch writes any.
    @ObservationIgnored private let screenSharingDefault: FreshInstallDefault

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        flags = defaults
        hadEarlierPreferences = FreshInstallDefault.Key.earlierPreferenceEvidence.contains { defaults.hasValue(forKey: $0) }
        screenSharingDefault = .screenSharing(store: defaults)
        hideFromScreenSharing = defaults.object(forKey: Key.hideFromScreenSharing) as? Bool ?? false
        side = defaults.string(forKey: Key.side).flatMap(DeckSide.init(rawValue:)) ?? .right
        display = defaults.string(forKey: Key.display).flatMap(DeckDisplay.init(rawValue:)) ?? .main
        if let data = defaults.data(forKey: Key.hotkey) {
            hotkey = data.isEmpty ? nil : try? JSONDecoder().decode(Hotkey.self, from: data)
        } else {
            hotkey = .default
        }
        folder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        face = defaults.string(forKey: Key.face).flatMap(NoteFace.init(rawValue:)) ?? .sans
        color = defaults.string(forKey: Key.color).flatMap(NoteColor.init(rawValue:)) ?? .coral
        autoArchiveDays = defaults.object(forKey: Key.autoArchiveDays) as? Int ?? 0
    }

    /// "Keep notes out of screen sharing", on once: when the install is
    /// demonstrably fresh (no earlier preferences, and `storageIsFresh` —
    /// true from source, nil while an official build's storage has not
    /// answered, which waits). Once decided, never revisited: an upgrade
    /// keeps what the user's screen shares showed before.
    func applyScreenSharingDefaultIfNeeded(storageIsFresh: Bool?) {
        guard screenSharingDefault.shouldTurnOn(isOn: hideFromScreenSharing, storageIsFresh: storageIsFresh) else { return }
        hideFromScreenSharing = true
    }

    /// Back to `~/Documents/OpenNotes`, which the app creates when missing.
    func resetFolder() {
        defaults.removeObject(forKey: Key.folder)
        folder = Self.defaultFolder
        defaults.removeObject(forKey: Key.folder)
    }

    /// `~/Documents/OpenNotes`; the update-test variant (scripts/update-e2e.sh)
    /// keeps its notes in its own Application Support folder instead, so a
    /// throwaway copy never reads or creates the user's.
    static var defaultFolder: URL {
        if UpdateTesting.isCompiledIn {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            return support.appendingPathComponent("OpenApps/opennotes-updatetest/Notes", isDirectory: true)
        }
        return NoteStore.defaultFolder()
    }

    /// The folder's path with the home folder as `~`.
    var folderDisplayPath: String {
        folder.path(percentEncoded: false).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
