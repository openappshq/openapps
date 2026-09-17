import AppKit
import CoreText
import Observation
import OpenNotesCore
import SwiftUI

/// The fonts installed on this Mac, as Settings → Notes and the note's
/// "Choose font…" list them: every family `NSFontManager` reports except
/// the system-private ones (a leading `.`), under its localised name,
/// sorted. Read again when Settings opens and whenever CoreText says the
/// registered fonts changed (Font Book installing or removing one).
@Observable
final class FontCatalog {
    struct Family: Identifiable, Hashable, Sendable {
        /// The family name `NSFont` is asked for, and what the file stores.
        let name: String
        /// What the list shows.
        let displayName: String
        var id: String { name }
    }

    static let shared = FontCatalog()

    private(set) var families: [Family] = []
    @ObservationIgnored private var names: Set<String> = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Reads the font manager again.
    func refresh() {
        let manager = NSFontManager.shared
        let visible = Self.visible(manager.availableFontFamilies)
        families = visible.map { Family(name: $0, displayName: manager.localizedName(forFamily: $0, face: nil)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        names = Set(visible)
        loaded = true
    }

    /// Whether a family can be rendered here. A family the manager does
    /// not list may still resolve (a font registered for this process
    /// after the last refresh), so `NSFont` is asked before saying no.
    func isInstalled(_ family: String) -> Bool {
        if !loaded { refresh() }
        if names.contains(family) { return true }
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: 12)?.familyName == family
    }

    /// The families the list shows: the private ones dropped, the rest as
    /// given. Pure, so the tests can feed it names.
    static func visible(_ families: [String]) -> [String] {
        families.filter { !$0.hasPrefix(".") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The families whose display or family name contains the query
    /// (case- and diacritic-insensitive); every family for an empty query.
    static func matching(_ query: String, in families: [Family]) -> [Family] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return families }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return families.filter { $0.displayName.range(of: trimmed, options: options) != nil || $0.name.range(of: trimmed, options: options) != nil }
    }
}

/// How a note looks, resolved from what the file says and what Settings
/// says: the paper and its ink for either appearance, the font it is
/// written in, and whether a font the file names is missing here. One
/// answer for the docked note, the fanned tab, All Notes' list and
/// preview card, and the harness.
struct NoteAppearance: Hashable {
    /// What notes without their own font read (Settings → Notes).
    struct Defaults: Hashable {
        var typeface: NoteTypeface = .face(.sans)
        var size: Int = NoteTypeface.defaultSize

        init(typeface: NoteTypeface = .face(.sans), size: Int = NoteTypeface.defaultSize) {
            self.typeface = typeface
            self.size = size
        }

        @MainActor init(_ preferences: Preferences) {
            typeface = preferences.typeface
            size = preferences.size
        }
    }

    /// The font the note renders in, after the fallback.
    enum Font: Hashable {
        case sans, serif, mono
        case family(String)

        init(_ typeface: NoteTypeface) {
            switch typeface {
            case .face(.sans): self = .sans
            case .face(.serif): self = .serif
            case .face(.mono): self = .mono
            case .family(let family): self = .family(family)
            }
        }

        var title: String {
            switch self {
            case .sans: "Sans"
            case .serif: "Serif"
            case .mono: "Mono"
            case .family(let family): family
            }
        }
    }

    var color: NoteColor
    var font: Font
    var size: CGFloat
    /// The note's own typeface as the file has it (nil: the default).
    var typeface: NoteTypeface?
    /// The note's own size as the file has it (nil: the default).
    var fontSize: Int?
    /// The family the file names that is not installed on this Mac: the
    /// note is shown in the default font and the footer says so. The file
    /// keeps the name, so the note comes back in it where the font is.
    var missingFamily: String?

    /// The one resolution: the note's font when it has one and it is
    /// installed, else the default (and if the default names a family that
    /// is gone too, Sans).
    static func resolve(color: NoteColor, typeface: NoteTypeface?, fontSize: Int?, defaults: Defaults, isInstalled: (String) -> Bool) -> NoteAppearance {
        var missing: String?
        var chosen = typeface ?? defaults.typeface
        if case .family(let family) = chosen, !isInstalled(family) {
            if typeface != nil { missing = family }
            chosen = defaults.typeface
            if case .family(let fallback) = chosen, !isInstalled(fallback) { chosen = .face(.sans) }
        }
        let points = NoteTypeface.clampSize(fontSize ?? defaults.size)
        return NoteAppearance(color: color, font: Font(chosen), size: CGFloat(points), typeface: typeface, fontSize: fontSize, missingFamily: missing)
    }

    @MainActor static func resolve(_ note: Note, defaults: Defaults, catalog: FontCatalog = .shared) -> NoteAppearance {
        resolve(color: note.color, typeface: note.typeface, fontSize: note.fontSize, defaults: defaults, isInstalled: catalog.isInstalled)
    }

    @MainActor static func resolve(_ note: Note, preferences: Preferences) -> NoteAppearance {
        resolve(note, defaults: Defaults(preferences))
    }

    /// The look for a face at a size, no file involved (the styler's
    /// default, the harness, the tests).
    init(color: NoteColor = .coral, font: Font = .sans, size: CGFloat = CGFloat(NoteTypeface.defaultSize), typeface: NoteTypeface? = nil, fontSize: Int? = nil, missingFamily: String? = nil) {
        self.color = color
        self.font = font
        self.size = size
        self.typeface = typeface
        self.fontSize = fontSize
        self.missingFamily = missingFamily
    }

    // MARK: Colours

    /// The paper for the appearance, as the note card and the preview
    /// card fill it.
    var paper: Color { dynamic { NSColor(hex: color.face(dark: $0)) } }
    /// Body text on the paper.
    var ink: Color { dynamic { NSColor(hex: color.ink(dark: $0)) } }
    /// Markers and metadata on the paper.
    var inkSecondary: Color { dynamic { NSColor(hex: color.inkSecondary(dark: $0)) } }
    /// The fanned tab and All Notes' colour bar: the paper itself, so the
    /// tab and the open note read as one colour in either appearance.
    var tab: Color { paper }
    /// The title read down the tab.
    var tabInk: Color { ink }
    /// All Notes' dash and the menu's swatch: the light paper in both.
    var swatch: Color { Color(nsColor: NSColor(hex: color.lightFace)) }

    func paperColor(dark: Bool) -> NSColor { NSColor(hex: color.face(dark: dark)) }
    func inkColor(dark: Bool) -> NSColor { NSColor(hex: color.ink(dark: dark)) }
    func inkSecondaryColor(dark: Bool) -> NSColor { NSColor(hex: color.inkSecondary(dark: dark)) }
    /// URLs and ticked boxes on the paper.
    func linkColor(dark: Bool) -> NSColor { NSColor(hex: color.link(dark: dark)) }

    private func dynamic(_ make: @escaping @Sendable (Bool) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            make(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
    }

    // MARK: Fonts

    /// The font at the note's size; a weight of 600 or more is bold, and
    /// italic comes from the family's own italic member when it has one.
    func nsFont(size: CGFloat? = nil, weight: CGFloat = 400, italic: Bool = false) -> NSFont {
        Brand.noteFont(font, size: size ?? self.size, weight: weight, italic: italic)
    }

    /// Whether the note's font is fixed-pitch, so checkboxes and bullets
    /// set in it line up with the text.
    var isMonospaced: Bool { nsFont().isFixedPitch }

    /// "Sans", or the family name, for footers.
    var fontTitle: String { font.title }

    /// What the note's footer says under the status line when the file's
    /// font is not here; nil otherwise.
    var missingFontNotice: String? {
        missingFamily.map { "“\($0)” isn’t installed on this Mac; shown in \(font.title)." }
    }
}
