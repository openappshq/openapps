import AppKit
import OpenNotesCore

/// The one door every automation entry point goes through: the
/// `opennotes://` links (AppDelegate, `openDeepLink`) and the Shortcuts
/// actions (the OpenNotesIntents module, bound at launch). Each request asks the projected
/// license at this moment (LICENSING.md: an entry point is an action) and
/// writes nothing when refused; the store asks once more at the file.
/// Writes go through the model's own create, text and close paths, so a
/// note made by a link is saved, named and sliding out exactly as one
/// typed by hand.
@MainActor
final class Automation {
    enum Failure: LocalizedError, Equatable {
        /// The license does not allow writing: the notice the footer shows.
        case readOnly(String)
        /// No note has this title.
        case noSuchNote(String)
        /// A note with no text is nothing to keep.
        case emptyText
        /// The store refused (the folder is missing, the disk is full): its words.
        case storage(String)
        /// The text or the title is over `AutomationLink`'s bound.
        case tooLong

        var errorDescription: String? {
            switch self {
            case .readOnly(let notice): notice
            case .noSuchNote(let title): "No note is titled “\(title)”."
            case .emptyText: "The note needs some text."
            case .storage(let message): message
            case .tooLong: "The text is too long for a note (\(AutomationLink.textLimit) characters at most)."
            }
        }
    }

    private let model: AppModel
    /// Slides the note out of the deck (All Notes' Open does the same).
    var openNote: (NoteID) -> Void = { _ in }
    /// The hotkey's new note, for `new` with no text.
    var newNote: () -> Void = {}
    /// A note that only All Notes can show (an archived one).
    var showAllNotes: () -> Void = {}
    /// A refused link: the note-shaped card that says writing waits for
    /// a license. Shortcuts get the same words as an error instead.
    var refuse: (String) -> Void = { _ in }

    init(model: AppModel) {
        self.model = model
    }

    /// A link: performed, or refused with the card; a missing note or a
    /// storage problem has nothing to show and is dropped.
    func openLink(_ request: AutomationRequest) {
        do {
            _ = try perform(request)
        } catch Failure.readOnly(let notice) {
            refuse(notice)
        } catch {
            // Nothing the link can be told; the deck and the folder are as they were.
        }
    }

    /// Performs one request; the license is asked at every write, and the
    /// text is bounded at the door (a link is dropped before this, an
    /// action fails with why).
    @discardableResult
    func perform(_ request: AutomationRequest) throws -> AutomationOutcome {
        guard AutomationLink.isBounded(request) else { throw Failure.tooLong }
        switch request {
        case .new(let text, let title, let color):
            let composed = AutomationLink.compose(title: title, text: text)
            guard !composed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try requireAccess()
                newNote()
                return .newNote
            }
            let id = try create(composed, color: color)
            openNote(id)
            return .created(id, model.store.fileURL(for: id))
        case .append(let title, let text):
            if let note = find(title) {
                try requireAccess()
                guard let body = model.body(of: note.id), body.bodyIsLoaded, !body.truncated else {
                    throw Failure.storage(StoreError.bodyUnavailable(note.id).localizedDescription)
                }
                let updated = AutomationLink.appending(text, to: body.text)
                model.setText(updated, for: note.id)
                guard model.note(note.id)?.text == updated else { throw Failure.storage(model.readOnly ? model.readOnlyNotice : "Couldn’t change the note.") }
                guard let saved = model.save(note.id) else { throw Failure.storage(model.readOnlyNotice) }
                return .appended(saved)
            }
            let id = try create(AutomationLink.compose(title: title, text: text), color: nil)
            return .appended(id)
        case .text(let title):
            guard let note = find(title), let body = model.body(of: note.id) else { throw Failure.noSuchNote(title) }
            // The whole text or nothing: never a summary or a preview.
            guard body.bodyIsLoaded else { throw Failure.storage(StoreError.bodyUnavailable(note.id).localizedDescription) }
            guard !body.truncated else { throw Failure.storage(StoreError.oversized(note.id).localizedDescription) }
            return .text(body.text)
        case .open(let title):
            guard let note = find(title) else { throw Failure.noSuchNote(title) }
            if note.archived { showAllNotes() } else { openNote(note.id) }
            return .opened(note.id)
        }
    }

    /// Active first, in deck order, then archived.
    private func find(_ title: String) -> Note? {
        AutomationLink.note(titled: title, in: model.active + model.archived)
    }

    private func requireAccess() throws {
        guard model.allowed() else { throw Failure.readOnly(model.readOnlyNotice) }
    }

    /// A note with this text, written now and given its title's file name,
    /// as a note closing does. Refused before anything is made.
    private func create(_ text: String, color: NoteColor?) throws -> NoteID {
        try requireAccess()
        guard let note = model.createNote() else { throw Failure.storage(model.saveProblem ?? model.readOnlyNotice) }
        if let color, color != note.color { model.setColor(color, for: note.id) }
        model.setText(text, for: note.id)
        guard model.note(note.id)?.text == text else {
            // Refused between the create and the text: the empty note is dropped.
            _ = model.closeNote(note.id)
            throw Failure.readOnly(model.readOnlyNotice)
        }
        guard let id = model.closeNote(note.id) else { throw Failure.emptyText }
        if let problem = model.saveProblem, model.store.hasUnsavedChanges(id) { throw Failure.storage(problem) }
        return id
    }
}
