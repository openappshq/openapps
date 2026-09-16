import Foundation

/// A note's identity: its file name without the `.md`, fixed on the first
/// save and never changed by the app (design/products/opennotes.md,
/// "Notes"), so iCloud Drive, Obsidian and git see one stable file.
nonisolated public struct NoteID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var fileName: String { rawValue + ".md" }
    public var description: String { rawValue }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The six sticky colors. Stored by name in the front matter; the faces
/// (apps/opennotes/design/tokens.json, `noteFaces`) are the app's.
nonisolated public enum NoteColor: String, CaseIterable, Sendable, Codable {
    case coral, yellow, mint, sky, lilac, paper

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The fill under ink text in Light Mode, also the tab and the pill dash
    /// in both appearances.
    public var lightFace: UInt32 {
        switch self {
        case .coral: 0xFFC0AB
        case .yellow: 0xFFE28A
        case .mint: 0xB1E7CA
        case .sky: 0xC1C9FF
        case .lilac: 0xF3C3E8
        case .paper: 0xF3F3F3
        }
    }

    /// The fill under paper text in Dark Mode.
    public var darkFace: UInt32 {
        switch self {
        case .coral: 0x4A1D12
        case .yellow: 0x4A3A0A
        case .mint: 0x163A29
        case .sky: 0x242B55
        case .lilac: 0x452040
        case .paper: 0x2C2C2C
        }
    }
}

/// The two faces a note can be written in.
nonisolated public enum NoteFace: String, CaseIterable, Sendable, Codable {
    case sans, mono

    public var title: String {
        switch self {
        case .sans: "Sans"
        case .mono: "Mono"
        }
    }

    public var toggled: NoteFace { self == .sans ? .mono : .sans }
}

/// One sticky: what the front matter keeps, and the text.
nonisolated public struct Note: Hashable, Sendable, Identifiable {
    public var id: NoteID
    public var text: String
    public var color: NoteColor
    public var face: NoteFace
    public var pinned: Bool
    public var archived: Bool
    /// Position in the deck, lower first. New notes take one below the
    /// lowest so they land on top; reordering rewrites the active notes'.
    public var order: Int
    public var created: Date
    /// The last edit made through the app or seen on disk.
    public var modified: Date

    public init(id: NoteID, text: String = "", color: NoteColor = .coral, face: NoteFace = .sans, pinned: Bool = false, archived: Bool = false, order: Int = 0, created: Date, modified: Date? = nil) {
        self.id = id
        self.text = text
        self.color = color
        self.face = face
        self.pinned = pinned
        self.archived = archived
        self.order = order
        self.created = created
        self.modified = modified ?? created
    }

    /// The first non-empty line, a leading heading marker dropped; "Untitled"
    /// when there is none. The deck's tab, the All Notes list and the file
    /// name (once) all read it.
    public var title: String {
        Note.title(of: text)
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text after the title line, trimmed, for the All Notes list.
    public var preview: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeSubrange(...first)
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func title(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            while trimmed.hasPrefix("#") { trimmed.removeFirst() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Untitled" : trimmed
        }
        return "Untitled"
    }

    /// The deck's order: pinned first, then by `order`, then the newest first,
    /// then by id so equal notes still sort the same on every launch.
    public static func deckOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.created != rhs.created { return lhs.created > rhs.created }
        return lhs.id < rhs.id
    }
}

/// The front matter of a note file: a `---` block of `key: value` lines
/// before the text. Only keys OpenNotes writes are read; a block that is
/// not ours (no known key at all) is left as text, so an Obsidian file with
/// its own front matter loses nothing (design/products/opennotes.md,
/// "Defaults and recovery").
nonisolated public enum FrontMatter {
    public static let keys = ["color", "face", "pinned", "archived", "order", "created", "modified"]

    public struct Parsed: Hashable, Sendable {
        public var color: NoteColor?
        public var face: NoteFace?
        public var pinned: Bool?
        public var archived: Bool?
        public var order: Int?
        public var created: Date?
        public var modified: Date?
        /// The text after the block (the whole file when there is none).
        public var text: String
        /// Whether a block OpenNotes recognises was found.
        public var hadFrontMatter: Bool

        public var isEmpty: Bool {
            color == nil && face == nil && pinned == nil && archived == nil && order == nil && created == nil && modified == nil
        }
    }

    /// Parses a file's contents. The block must start on the first line and
    /// close with a `---` line; unknown keys are ignored, and a block with
    /// no known key is not consumed.
    public static func parse(_ contents: String) -> Parsed {
        var result = Parsed(text: contents, hadFrontMatter: false)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return result }
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return result }
        var known = false
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "color": if let color = NoteColor(rawValue: value.lowercased()) { result.color = color; known = true }
            case "face": if let face = NoteFace(rawValue: value.lowercased()) { result.face = face; known = true }
            case "pinned": if let flag = bool(value) { result.pinned = flag; known = true }
            case "archived": if let flag = bool(value) { result.archived = flag; known = true }
            case "order": if let order = Int(value) { result.order = order; known = true }
            case "created": if let date = date(value) { result.created = date; known = true }
            case "modified": if let date = date(value) { result.modified = date; known = true }
            default: break
            }
        }
        guard known else { return result }
        result.hadFrontMatter = true
        result.text = lines[(close + 1)...].joined(separator: "\n")
        return result
    }

    /// The file's contents for a note: the block, a blank line, the text.
    /// Dates are ISO 8601 in UTC, so a folder shared between Macs in
    /// different zones reads the same.
    public static func serialize(_ note: Note) -> String {
        let block = """
        ---
        color: \(note.color.rawValue)
        face: \(note.face.rawValue)
        pinned: \(note.pinned)
        archived: \(note.archived)
        order: \(note.order)
        created: \(format(note.created))
        modified: \(format(note.modified))
        ---
        """
        return block + "\n\n" + note.text
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(_ value: String) -> Date? {
        formatter.date(from: value) ?? fractionalFormatter.date(from: value)
    }
}

/// File names from titles: lowercase ASCII letters, digits and hyphens,
/// 60 characters at most; a counter when the name is taken; a timestamp
/// when there is no title.
nonisolated public enum NoteFileName {
    public static let maximumLength = 60

    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                if pendingHyphen, !result.isEmpty {
                    guard result.count + 1 < maximumLength else { break }
                    result.append("-")
                }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
            if result.count >= maximumLength { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    /// The id for a new note: the title's slug (or `note-<timestamp>`), with
    /// `-2`, `-3`, … while `taken` says the name is in use.
    public static func id(for title: String, created: Date, taken: (NoteID) -> Bool) -> NoteID {
        var base = slug(title == "Untitled" ? "" : title)
        if base.isEmpty {
            base = "note-" + timestampFormatter.string(from: created)
        }
        var candidate = NoteID(base)
        var counter = 2
        while taken(candidate) {
            candidate = NoteID("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    /// `<name> (conflict 2026-09-16 10-30-05).md`, beside the note.
    public static func conflictName(for id: NoteID, at date: Date) -> String {
        "\(id.rawValue) (conflict \(conflictFormatter.string(from: date))).md"
    }

    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    nonisolated(unsafe) private static let conflictFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}
