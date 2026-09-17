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

    /// When the next unpinned active note falls due, so the app can wake
    /// then instead of on a schedule; nil when nothing can fall due.
    public static func nextDue(in notes: [Note], days: Int) -> Date? {
        guard days > 0 else { return nil }
        return notes.filter { !$0.archived && !$0.pinned }.map { $0.modified.addingTimeInterval(Double(days) * 86_400) }.min()
    }
}

/// The 10-second Undo after Archive (design/products/opennotes.md,
/// "Notes"): the most recent archive can be undone until its deadline;
/// older ones expire on their own. A batch from All Notes — several
/// notes archived or restored at once — is one entry and one undo. Pure,
/// with an injected clock.
nonisolated public struct ArchiveUndo: Hashable, Sendable {
    public static let window: TimeInterval = 10

    /// What the undo puts back.
    public enum Kind: Hashable, Sendable {
        /// The notes were archived: undo restores them.
        case archived
        /// The notes were restored: undo archives them again.
        case restored
    }

    public struct Pending: Hashable, Sendable {
        /// The notes in the batch, in the order they were acted on; one
        /// for the deck's own archive.
        public let ids: [NoteID]
        /// The first note's title (the toast's word for a single archive).
        public let title: String
        public let deadline: Date
        public let kind: Kind

        public init(id: NoteID, title: String, deadline: Date) {
            self.init(ids: [id], title: title, deadline: deadline, kind: .archived)
        }

        public init(ids: [NoteID], title: String, deadline: Date, kind: Kind) {
            self.ids = ids
            self.title = title
            self.deadline = deadline
            self.kind = kind
        }

        /// The first note: what a single archive's toast names.
        public var id: NoteID { ids[0] }

        public var count: Int { ids.count }

        /// The toast's line: the title for one note, the count for a batch.
        public var message: String {
            let verb = kind == .archived ? "Archived" : "Restored"
            return count == 1 ? "\(verb) “\(title)”" : "\(verb) \(count) notes"
        }
    }

    public private(set) var pending: [Pending] = []

    public init() {}

    /// The archive the toast offers to undo, if any is still within its window.
    public func current(at now: Date) -> Pending? {
        pending.last { $0.deadline > now }
    }

    public mutating func archived(_ id: NoteID, title: String, at now: Date) {
        archived([id], title: title, at: now)
    }

    /// A batch archived together: one entry, undone together. Empty
    /// batches register nothing.
    public mutating func archived(_ ids: [NoteID], title: String, at now: Date) {
        add(ids, title: title, kind: .archived, at: now)
    }

    /// A batch restored together (All Notes → Archived → Restore): one
    /// entry whose undo archives them again.
    public mutating func restored(_ ids: [NoteID], title: String, at now: Date) {
        add(ids, title: title, kind: .restored, at: now)
    }

    private mutating func add(_ ids: [NoteID], title: String, kind: Kind, at now: Date) {
        guard !ids.isEmpty else { return }
        forget(ids)
        pending.append(Pending(ids: ids, title: title, deadline: now.addingTimeInterval(Self.window), kind: kind))
        expire(at: now)
    }

    /// The note to restore, and the entry is gone.
    public mutating func undo(at now: Date) -> NoteID? {
        undoPending(at: now)?.id
    }

    /// The latest entry within its window, removed: its notes go back the
    /// way `kind` says.
    public mutating func undoPending(at now: Date) -> Pending? {
        expire(at: now)
        return pending.popLast()
    }

    public mutating func expire(at now: Date) {
        pending.removeAll { $0.deadline <= now }
    }

    /// A note acted on again (restored by hand, archived once more) leaves
    /// the entry it was in; an entry left with no note is gone.
    public mutating func forget(_ id: NoteID) {
        forget([id])
    }

    public mutating func forget(_ ids: [NoteID]) {
        let gone = Set(ids)
        pending = pending.compactMap { entry in
            let kept = entry.ids.filter { !gone.contains($0) }
            guard !kept.isEmpty else { return nil }
            guard kept.count != entry.ids.count else { return entry }
            return Pending(ids: kept, title: entry.title, deadline: entry.deadline, kind: entry.kind)
        }
    }
}
