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

    /// The bar along a tab's outer edge: the colour's own mid tone, so
    /// the papers tell apart at a glance in both appearances.
    public var bar: UInt32 {
        switch self {
        case .coral: 0xF0653F
        case .yellow: 0xE3B517
        case .mint: 0x3FAE79
        case .sky: 0x6F7FF2
        case .lilac: 0xD56DBC
        case .paper: 0xA3A3A3
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
    /// The file is larger than the store reads: `text` is its beginning,
    /// and the note is shown but never edited or written. Not persisted.
    public var truncated = false
    /// `text` is the whole body (as far as the read cap goes). False once
    /// the store's body budget evicted it: `text` is then the first
    /// kilobyte, and `NoteStore.body(of:)` reads the rest back. Not persisted.
    public var bodyIsLoaded = true

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

    /// The text after the title line as one line for the All Notes list:
    /// the lines joined with spaces, the markers gone (headings, emphasis,
    /// code, bullets and checkboxes), read line by line only until
    /// `previewLength` characters are in hand (the line that crosses it is
    /// kept whole), so a long note costs no more than a short one.
    public var preview: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeSubrange(...first)
        }
        var kept: [String] = []
        var length = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            kept.append(trimmed)
            length += trimmed.count + 1
            if length >= Note.previewLength { break }
        }
        guard !kept.isEmpty else { return "" }
        let plain = MarkdownLite.plainText(kept.joined(separator: "\n"))
        return plain.split(separator: "\n").map { Note.withoutListMarker(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// How much of the text the preview reads before it stops taking
    /// lines, in characters; far more than a row shows.
    public static let previewLength = 240

    /// The line without a leading bullet, number or checkbox.
    static func withoutListMarker(_ line: String) -> String {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            rest = rest.dropFirst(2)
        } else if let dot = rest.firstIndex(of: "."), rest[..<dot].allSatisfy(\.isNumber), !rest[..<dot].isEmpty, rest[rest.index(after: dot)...].hasPrefix(" ") {
            rest = rest[rest.index(after: dot)...].dropFirst()
        }
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) {
            rest = rest.dropFirst(box.count)
            break
        }
        if rest == "[ ]" || rest == "[x]" || rest == "[X]" { return "" }
        return rest.trimmingCharacters(in: .whitespaces)
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

    /// Orders outside this range (a hand-written file, an overflow) are
    /// brought back to its edge on read, so "one below the lowest" is
    /// always a number.
    public static let orderRange: ClosedRange<Int> = -1_000_000_000...1_000_000_000

    public static func clampOrder(_ order: Int) -> Int {
        min(max(order, orderRange.lowerBound), orderRange.upperBound)
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
        /// The text after the block (the whole file when there is none),
        /// the one blank line `serialize` puts after the block dropped, so
        /// `parse(serialize(note)).text == note.text`.
        public var text: String
        /// Whether a block OpenNotes recognises was found.
        public var hadFrontMatter: Bool

        public var isEmpty: Bool {
            color == nil && face == nil && pinned == nil && archived == nil && order == nil && created == nil && modified == nil
        }
    }

    /// Parses a file's contents. The block must start on the first line and
    /// close with a `---` line; unknown keys are ignored, and a block with
    /// no known key is not consumed. The blank line `serialize` writes after
    /// the block is the file's, not the text's: one is dropped.
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
        var text = lines[(close + 1)...].joined(separator: "\n")
        if text.hasPrefix("\n") { text.removeFirst() }
        result.text = text
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

    /// `<name> (conflict 2026-09-16 10-30-05.123)`, the stem of the note
    /// beside the original that holds the user's text; the store adds
    /// `-2`, `-3`… while the name is taken.
    public static func conflictStem(for id: NoteID, at date: Date) -> String {
        "\(id.rawValue) (conflict \(conflictFormatter.string(from: date)))"
    }

    public static func conflictName(for id: NoteID, at date: Date) -> String {
        conflictStem(for: id, at: date) + ".md"
    }

    /// `<name> (recovered 2026-09-16 10-30-05.123)`: a version found in a
    /// temporary file a cut-short write left behind.
    public static func recoveredStem(for stem: String, at date: Date) -> String {
        "\(stem) (recovered \(conflictFormatter.string(from: date)))"
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
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss.SSS"
        return formatter
    }()
}
