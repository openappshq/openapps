import Foundation

nonisolated public enum ExportFormat: String, CaseIterable, Sendable {
    /// The text as saved, without the front matter.
    case markdown = "md"
    /// The text with the markers stripped (`MarkdownLite.plainText`).
    case plainText = "txt"

    public var title: String {
        switch self {
        case .markdown: "Markdown (.md)"
        case .plainText: "Plain text (.txt)"
        }
    }
}

/// Export: what All Notes writes through the save panel. Pure.
nonisolated public enum Export {
    public static func file(for note: Note, as format: ExportFormat) -> (name: String, data: Data) {
        let stem = NoteFileName.slug(note.title)
        let name = (stem.isEmpty ? note.id.rawValue : stem) + "." + format.rawValue
        let text: String
        switch format {
        case .markdown: text = note.text
        case .plainText: text = MarkdownLite.plainText(note.text)
        }
        return (name, Data(text.utf8))
    }
}

/// Search over titles and text, case- and diacritic-insensitive, every
/// word of the query somewhere in the note. Results keep the given order.
nonisolated public enum Search {
    public static func matches(_ query: String, in notes: [Note]) -> [Note] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return notes }
        return notes.filter { note in
            let haystack = fold(note.text)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Auto-archive (Settings → Notes): unpinned active notes untouched for
/// longer than the chosen number of days. Pure; the app runs it at launch
/// and hourly.
nonisolated public enum AutoArchive {
    public static let choices: [Int] = [0, 7, 30, 90]

    public static func title(days: Int) -> String {
        days == 0 ? "Off" : "After \(days) days"
    }

    /// The notes to archive now. `days` 0 is off.
    public static func candidates(in notes: [Note], days: Int, now: Date) -> [NoteID] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return notes.filter { !$0.archived && !$0.pinned && $0.modified < cutoff }.map(\.id).sorted()
    }
}

/// The 10-second Undo after Archive (design/products/opennotes.md,
/// "Notes"): the most recent archive can be undone until its deadline;
/// older ones expire on their own. Pure, with an injected clock.
nonisolated public struct ArchiveUndo: Hashable, Sendable {
    public static let window: TimeInterval = 10

    public struct Pending: Hashable, Sendable {
        public let id: NoteID
        public let title: String
        public let deadline: Date
    }

    public private(set) var pending: [Pending] = []

    public init() {}

    /// The archive the toast offers to undo, if any is still within its window.
    public func current(at now: Date) -> Pending? {
        pending.last { $0.deadline > now }
    }

    public mutating func archived(_ id: NoteID, title: String, at now: Date) {
        pending.removeAll { $0.id == id }
        pending.append(Pending(id: id, title: title, deadline: now.addingTimeInterval(Self.window)))
        expire(at: now)
    }

    /// The note to restore, and the entry is gone.
    public mutating func undo(at now: Date) -> NoteID? {
        expire(at: now)
        guard let last = pending.popLast() else { return nil }
        return last.id
    }

    public mutating func expire(at now: Date) {
        pending.removeAll { $0.deadline <= now }
    }

    public mutating func forget(_ id: NoteID) {
        pending.removeAll { $0.id == id }
    }
}
