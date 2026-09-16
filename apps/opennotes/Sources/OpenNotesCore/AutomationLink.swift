import Foundation

/// What the automation entry points ask for (design/products/opennotes.md,
/// "Automation"): the `opennotes://` links and the Shortcuts actions both
/// reduce to one of these, and the app performs them through one door
/// that asks the license first.
nonisolated public enum AutomationRequest: Hashable, Sendable {
    /// A new note with this text (the title, when given, becomes its first
    /// line) and color (the default when nil), slid out of the deck. An
    /// empty text is the hotkey: an empty note, focused.
    case new(text: String, title: String?, color: NoteColor?)
    /// The note whose title matches, slid out.
    case open(title: String)
    /// A line added to the note whose title matches; a new note with
    /// that title when none does.
    case append(title: String, text: String)
    /// The text of the note whose title matches (Shortcuts only).
    case text(title: String)
}

/// What a request did.
nonisolated public enum AutomationOutcome: Hashable, Sendable {
    /// A note was created; its file, under the name the title gave it.
    case created(NoteID, URL)
    case appended(NoteID)
    case text(String)
    case opened(NoteID)
    /// `new` with no text: the hotkey's empty note, focused.
    case newNote
}

/// `opennotes://new?text=…&title=…&color=…`, `opennotes://open?title=…`
/// and `opennotes://append?title=…&text=…`: parsed with the usual
/// percent-decoding; a `+` stays a `+` (a sum in the text is a sum).
/// Anything else — another host, a missing title — is nil.
nonisolated public enum AutomationLink {
    public static let scheme = "opennotes"

    public static func request(from url: URL) -> AutomationRequest? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let title = value("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch host {
        case "new":
            let color = value("color").flatMap { NoteColor(rawValue: $0.lowercased()) }
            return .new(text: value("text") ?? "", title: title.flatMap { $0.isEmpty ? nil : $0 }, color: color)
        case "open":
            guard let title, !title.isEmpty else { return nil }
            return .open(title: title)
        case "append":
            guard let title, !title.isEmpty, let text = value("text"), !text.trimmingCharacters(in: .newlines).isEmpty else { return nil }
            return .append(title: title, text: text)
        default:
            return nil
        }
    }

    /// The text a new note gets: the title as its first line, then the text.
    public static func compose(title: String?, text: String) -> String {
        guard let title, !title.isEmpty else { return text }
        return text.isEmpty ? title : title + "\n" + text
    }

    /// The text after a line is appended: on its own line, after a
    /// terminator when the text has none.
    public static func appending(_ line: String, to text: String) -> String {
        if text.isEmpty { return line }
        return text.hasSuffix("\n") ? text + line : text + "\n" + line
    }

    /// The note a title names: the first whose title is the query
    /// (case- and diacritic-insensitive), else the first whose title
    /// starts with it, else the first whose title contains it. The notes
    /// are searched in the order given (active first, in deck order, then
    /// archived).
    public static func note(titled query: String, in notes: [Note]) -> Note? {
        let wanted = Search.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return nil }
        let titles = notes.map { Search.fold($0.title) }
        if let index = titles.firstIndex(of: wanted) { return notes[index] }
        if let index = titles.firstIndex(where: { $0.hasPrefix(wanted) }) { return notes[index] }
        if let index = titles.firstIndex(where: { $0.contains(wanted) }) { return notes[index] }
        return nil
    }
}
