import Foundation
import OpenNotesCore

/// The checked notes in All Notes (design/products/opennotes.md, "All
/// Notes"): a set over the rows on view, with the row the last click
/// landed on as the anchor a ⇧-click ranges from. Pure; the view keeps
/// one in its session and hands it the visible rows, in list order, for
/// every question that depends on them. A checked note that leaves the
/// list (a narrower search, the other scope, a file gone) leaves the set
/// (`keep`): what is checked is always on view, so a bulk action never
/// reaches a note the user cannot see.
struct AllNotesSelection: Equatable {
    private(set) var checked: Set<NoteID> = []
    /// Where the last toggle landed: the start of the next ⇧-click's range.
    private(set) var anchor: NoteID?

    var isEmpty: Bool { checked.isEmpty }
    var count: Int { checked.count }

    func contains(_ id: NoteID) -> Bool { checked.contains(id) }

    /// The checkbox click, or Space on the focused row.
    mutating func toggle(_ id: NoteID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
        anchor = id
    }

    /// ⇧-click: every row from the anchor to this one is checked (never
    /// unchecked), the anchor staying put so a second ⇧-click widens or
    /// narrows the same range. Without an anchor on view it is a toggle.
    mutating func extend(to id: NoteID, in visible: [NoteID]) {
        guard let anchor, let from = visible.firstIndex(of: anchor), let to = visible.firstIndex(of: id) else {
            toggle(id)
            return
        }
        let range = min(from, to)...max(from, to)
        checked.formUnion(visible[range])
    }

    /// ⌘A, or the header's checkbox from none or some.
    mutating func checkAll(_ visible: [NoteID]) {
        checked = Set(visible)
        if anchor == nil { anchor = visible.first }
    }

    /// Esc, Clear, or the header's checkbox from all.
    mutating func clear() {
        checked = []
        anchor = nil
    }

    /// The set after the list changed: only rows still on view stay.
    mutating func keep(_ visible: [NoteID]) {
        let shown = Set(visible)
        checked = checked.intersection(shown)
        if let anchor, !shown.contains(anchor) { self.anchor = nil }
    }

    /// The checked rows in list order: the order every bulk action takes.
    func ordered(in visible: [NoteID]) -> [NoteID] {
        visible.filter { checked.contains($0) }
    }

    /// The header checkbox: every row, some, or none.
    enum Coverage: Equatable { case none, some, all }

    func coverage(of visible: [NoteID]) -> Coverage {
        let shown = ordered(in: visible).count
        if shown == 0 { return .none }
        return shown == visible.count ? .all : .some
    }
}

/// The chips in the selection bar at the foot of the list, in order;
/// pure, so the tests read the bar for a scope and a license without a
/// window. Archive (Restore under Archived) leads, Clear is last, Delete…
/// only under Archived; read-only keeps Export…, Reveal and Clear.
enum AllNotesBulkAction: String, Identifiable, CaseIterable {
    case archive, restore, pin, unpin, colour, font, export, reveal, delete, clear

    var id: String { rawValue }

    static func bar(archived: Bool, readOnly: Bool, allPinned: Bool) -> [AllNotesBulkAction] {
        var actions: [AllNotesBulkAction] = []
        if !readOnly {
            if archived {
                actions.append(.restore)
            } else {
                actions += [.archive, allPinned ? .unpin : .pin, .colour, .font]
            }
        }
        actions += [.export, .reveal]
        if !readOnly, archived { actions.append(.delete) }
        actions.append(.clear)
        return actions
    }

    /// The chip's word.
    var title: String {
        switch self {
        case .archive: "Archive"
        case .restore: "Restore"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .colour: "Colour"
        case .font: "Font"
        case .export: "Export…"
        case .reveal: "Reveal"
        case .delete: "Delete…"
        case .clear: "Clear"
        }
    }
}

/// What the line under the split says after a bulk action, until the next
/// one or Clear: the notes the store refused with why, or the files that
/// went to the Trash (with the way to them).
enum AllNotesNotice: Equatable {
    /// "2 of 5 skipped: …" — nothing while every note went through.
    case skipped(count: Int, of: Int, reasons: [String])
    /// "Moved 3 notes to the Trash · Show in Finder".
    case trashed(count: Int, urls: [URL])

    /// The refusals of an outcome as a notice; nil when there were none.
    static func refusals(in outcome: AppModel.BulkOutcome) -> AllNotesNotice? {
        guard !outcome.skipped.isEmpty else { return nil }
        var reasons: [String] = []
        for skip in outcome.skipped where !reasons.contains(skip.reason) { reasons.append(skip.reason) }
        return .skipped(count: outcome.skipped.count, of: outcome.attempted, reasons: reasons)
    }

    var text: String {
        switch self {
        case .skipped(let count, let of, let reasons): AllNotesText.skipped(count, of: of, reasons: reasons)
        case .trashed(let count, _): AllNotesText.trashed(count)
        }
    }

    /// The Trash notice leaves on its own; a refusal stays until the next
    /// action, since it says what to do.
    var expires: Bool {
        if case .trashed = self { return true }
        return false
    }
}

/// Export… on the checked set: one file per note into the chosen folder,
/// each named as the single-note export names it, and no two alike — a
/// second "groceries.md" in the batch or already in the folder becomes
/// "groceries-2.md"; `plan` names, `write` creates.
enum AllNotesExport {
    struct Plan: Equatable {
        let id: NoteID
        let name: String
        let data: Data
    }

    /// The files into the folder, each created exclusively (never over a
    /// file that appeared since the plan looked): the notes written, and
    /// the ones that could not be, with why.
    static func write(_ notes: [Note], as format: ExportFormat, into folder: URL, fileManager: FileManager = .default) -> AppModel.BulkOutcome {
        var outcome = AppModel.BulkOutcome()
        let plans = plan(notes, as: format) { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        for plan in plans {
            do {
                try plan.data.write(to: folder.appendingPathComponent(plan.name), options: .withoutOverwriting)
                outcome.done.append(plan.id)
            } catch {
                outcome.skipped.append(.init(id: plan.id, reason: "\(plan.name): \(error.localizedDescription)"))
            }
        }
        return outcome
    }

    /// `taken` says whether a name is already in the folder.
    static func plan(_ notes: [Note], as format: ExportFormat, taken: (String) -> Bool) -> [Plan] {
        var used: Set<String> = []
        return notes.map { note in
            let file = Export.file(for: note, as: format)
            let stem = String(file.name.dropLast(format.rawValue.count + 1))
            var name = file.name
            var suffix = 2
            while used.contains(name) || taken(name) {
                name = "\(stem)-\(suffix).\(format.rawValue)"
                suffix += 1
            }
            used.insert(name)
            return Plan(id: note.id, name: name, data: file.data)
        }
    }
}
