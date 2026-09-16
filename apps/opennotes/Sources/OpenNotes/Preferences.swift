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
        /// A family chosen as the default; set, it wins over `face`.
        static let font = "notes.font"
        static let size = "notes.size"
        static let color = "notes.color"
        static let autoArchiveDays = "notes.autoArchiveDays"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// The first-run flags share the defaults domain (`FlagStore`): the
    /// welcome note's decision is kept there, beside the guide's.
    @ObservationIgnored let flags: any FlagStore
    /// An earlier launch left preferences behind (`FreshInstallDefault`),
    /// read when this is created, before the current launch writes any:
    /// the install is not fresh, and the welcome note is not for it.
    @ObservationIgnored let hadEarlierPreferences: Bool
    /// The display default applies to this install and is not recorded yet.
    @ObservationIgnored private var pendingDisplayDefault = false

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
    /// The default face; `typeface` is what notes without their own read.
    /// Where the notes live, read off the folder: the default folder is
    /// "On this Mac", the iCloud Drive folder is "iCloud Drive", anything
    /// else "Other folder". Nothing is stored beyond the folder itself.
    var storage: StorageChoice {
        if usesDefaultFolder || folder.standardizedFileURL.path == Self.defaultFolder.standardizedFileURL.path { return .thisMac }
        if folder.standardizedFileURL.path == Self.iCloudFolder.standardizedFileURL.path { return .iCloudDrive }
        return .other
    }
    /// The two folders the app makes when they are missing: its default
    /// and the iCloud Drive one (Finder shows it under iCloud Drive as
    /// "OpenNotes"). A chosen folder is never created.
    var createsFolder: Bool { storage != .other }
    var face: NoteFace {
        didSet { defaults.set(face.rawValue, forKey: Key.face) }
    }
    /// A family installed on this Mac chosen as the default, by name; nil
    /// leaves `face` as the default.
    var font: String? {
        didSet {
            if let font { defaults.set(font, forKey: Key.font) } else { defaults.removeObject(forKey: Key.font) }
        }
    }
    /// The default point size (`NoteTypeface.sizeRange`).
    var size: Int {
        didSet { defaults.set(size, forKey: Key.size) }
    }
    /// Notes without a font of their own render in this; new notes carry
    /// none, so they follow it.
    var typeface: NoteTypeface {
        get { font.map(NoteTypeface.family) ?? .face(face) }
        set {
            switch newValue {
            case .face(let newFace):
                font = nil
                face = newFace
            case .family(let family):
                font = family
            }
        }
    }
    /// "Sans · 14", for the diagnostics.
    var defaultFontDescription: String { "\(typeface.title) · \(size) pt" }
    /// The paper a new note takes: a random preset (fresh installs, and
    /// anyone who never chose one) or a fixed colour.
    var newNoteColor: NewNoteColor {
        didSet { defaults.set(newNoteColor.rawValue, forKey: Key.color) }
    }
    /// 0 is off.
    var autoArchiveDays: Int {
        didSet { defaults.set(autoArchiveDays, forKey: Key.autoArchiveDays) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        flags = defaults
        hadEarlierPreferences = FreshInstallDefault.Key.earlierPreferenceEvidence.contains { defaults.hasValue(forKey: $0) }
        side = defaults.string(forKey: Key.side).flatMap(DeckSide.init(rawValue:)) ?? .right
        // Every display on a fresh install; an install with earlier
        // preferences and no stored choice keeps the main display it had.
        // Nothing is written here: the launch's other defaults (the login
        // item, the updater) read the evidence after this, and a write now
        // would be an earlier launch to them. `commitLaunchDefaults`
        // records it once they have.
        let stored = defaults.string(forKey: Key.display).flatMap(DeckDisplay.init(rawValue:))
        pendingDisplayDefault = FreshInstallDefault.display(store: defaults).wouldApply(isSet: stored != nil)
        display = stored ?? (pendingDisplayDefault ? .every : .main)
        if let data = defaults.data(forKey: Key.hotkey) {
            hotkey = data.isEmpty ? nil : try? JSONDecoder().decode(Hotkey.self, from: data)
        } else {
            hotkey = .default
        }
        folder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        face = defaults.string(forKey: Key.face).flatMap(NoteFace.init(rawValue:)) ?? .sans
        font = defaults.string(forKey: Key.font).flatMap { $0.isEmpty ? nil : $0 }
        size = NoteTypeface.clampSize(defaults.object(forKey: Key.size) as? Int ?? NoteTypeface.defaultSize)
        newNoteColor = defaults.string(forKey: Key.color).flatMap(NewNoteColor.init(rawValue:)) ?? .random
        autoArchiveDays = defaults.object(forKey: Key.autoArchiveDays) as? Int ?? 0
    }

    /// Records the fresh-install decisions read at init (the display
    /// default: stored as the choice, and the flag either way), called by
    /// the launch once every other default has read the evidence. Safe
    /// to call again; nothing is written after the first time.
    func commitLaunchDefaults() {
        let display = FreshInstallDefault.display(store: defaults)
        if pendingDisplayDefault {
            pendingDisplayDefault = false
            defaults.set(DeckDisplay.every.rawValue, forKey: Key.display)
        }
        if !display.isDecided { display.markDecided() }
    }

    /// Back to `~/Documents/OpenNotes`, which the app creates when missing.
    func resetFolder() {
        defaults.removeObject(forKey: Key.folder)
        folder = Self.defaultFolder
        defaults.removeObject(forKey: Key.folder)
    }

    /// The colour for the next new note, given the deck: the fixed one, or
    /// a preset picked away from the last note created and the new note's
    /// neighbours (`NotePaper.randomForNewNote`).
    func colorForNewNote(active: [Note], lastCreated: Note?, seed: Int) -> NoteColor {
        switch newNoteColor {
        case .fixed(let color): color
        case .random: .preset(NotePaper.randomForNewNote(active: active, lastCreated: lastCreated, seed: seed))
        }
    }

    /// The iCloud Drive folder, `~/Library/Mobile Documents/com~apple~CloudDocs/OpenNotes`.
    static var iCloudFolder: URL { ICloudDrive.folder() }

    /// Whether iCloud Drive can be chosen: signed in, with iCloud Drive on.
    static var iCloudIsAvailable: Bool { ICloudDrive.isAvailable() }

    /// The choice from Settings or the guide. "Other folder…" is the
    /// chooser's job (`folder` set to what it returned); nothing changes
    /// for it here.
    func setStorage(_ choice: StorageChoice) {
        switch choice {
        case .thisMac: resetFolder()
        case .iCloudDrive: folder = Self.iCloudFolder
        case .other: break
        }
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

/// Settings → Notes → New notes: Random, or one colour for every new note.
/// Stored under `notes.color` as "random" or the colour's own value, so a
/// 0.1.0 preference (a preset name) reads as that fixed colour.
enum NewNoteColor: Hashable, RawRepresentable {
    case random
    case fixed(NoteColor)

    var rawValue: String {
        switch self {
        case .random: "random"
        case .fixed(let color): color.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue.lowercased() == "random" {
            self = .random
        } else if let color = NoteColor(rawValue: rawValue) {
            self = .fixed(color)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .random: "Random"
        case .fixed(let color): color.title
        }
    }

    var fixedColor: NoteColor? {
        if case .fixed(let color) = self { return color }
        return nil
    }
}
