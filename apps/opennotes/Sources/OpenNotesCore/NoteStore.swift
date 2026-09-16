import Foundation

/// What the store tells the app after a change it made or found.
nonisolated public enum StoreEvent: Hashable, Sendable {
    /// The folder was (re)read: everything may have changed.
    case reloaded
    /// These notes changed (edited here, or found changed on disk).
    case updated([NoteID])
    /// These files are gone from the folder.
    case removed([NoteID])
    /// A note's file took its final name when it first closed.
    case renamed(from: NoteID, to: NoteID)
    /// An outside edit lost to ours; the outside version is at the URL.
    case conflict(NoteID, copy: URL)
    /// The chosen folder is not there; nothing is read or written.
    case folderMissing
}

nonisolated public enum StoreError: Error, LocalizedError, Hashable {
    /// The trial ended or a license is needed: creating and editing refused.
    case readOnly
    case folderMissing(URL)
    case noSuchNote(NoteID)

    public var errorDescription: String? {
        switch self {
        case .readOnly: "OpenNotes is read-only until it is licensed."
        case .folderMissing(let url): "Can’t find the notes folder at \(url.path)."
        case .noSuchNote(let id): "No note named \(id.rawValue)."
        }
    }
}

/// How a save went.
nonisolated public enum SaveOutcome: Hashable, Sendable {
    /// Nothing to write.
    case unchanged
    case saved
    /// Saved over an outside edit; the outside version is at the URL.
    case savedOverConflict(URL)
    /// A new note with no text was not written.
    case notWritten
}

/// The notes folder: one `.md` file per note, read at launch and whenever
/// the watcher or the app asks (`rescan`), written 250 ms after typing
/// stops and at once for everything else. Last-writer-wins with a conflict
/// copy; nothing is ever deleted (design/products/opennotes.md, "Notes").
/// Main-actor: the app calls it from its windows; the watcher hops over.
public final class NoteStore {
    public private(set) var folder: URL
    public private(set) var notes: [NoteID: Note] = [:]
    /// The folder could not be found on the last read or write.
    public private(set) var folderIsMissing = false
    /// Creating and editing are refused (the trial ended, a license is
    /// needed); reading, exporting, archiving and reordering still work.
    public var readOnly = false
    public var onEvent: (StoreEvent) -> Void = { _ in }

    private let fileManager: FileManager
    private let now: () -> Date
    /// What the file held when it was last read or written, to tell an
    /// outside edit from our own.
    private var fingerprints: [NoteID: Fingerprint] = [:]
    /// Notes with in-memory text not yet on disk.
    private var dirty: Set<NoteID> = []
    /// Notes whose file changed on disk while `dirty`: the disk contents,
    /// kept for the conflict copy the next save writes.
    private var outsideEdits: [NoteID: String] = [:]
    /// Notes created this session and not yet closed once: their file is
    /// provisional and takes the title's name when they close.
    private var provisional: Set<NoteID> = []

    private struct Fingerprint: Equatable {
        var size: Int
        var modified: Date
        var hash: Int
    }

    public init(folder: URL, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.fileManager = fileManager
        self.now = now
    }

    /// The default folder, `~/Documents/OpenNotes`.
    public static func defaultFolder(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("OpenNotes", isDirectory: true)
    }

    // MARK: - Reading

    /// The deck's notes, in deck order.
    public var active: [Note] {
        notes.values.filter { !$0.archived }.sorted(by: Note.deckOrder)
    }

    /// Newest change first.
    public var archived: [Note] {
        notes.values.filter(\.archived).sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id }
    }

    public func note(_ id: NoteID) -> Note? { notes[id] }

    public func fileURL(for id: NoteID) -> URL {
        folder.appendingPathComponent(id.fileName, isDirectory: false)
    }

    public func hasUnsavedChanges(_ id: NoteID) -> Bool { dirty.contains(id) }

    /// Reads the folder, creating it when `create` (the default folder is
    /// always created; a chosen one never is). Replaces everything in
    /// memory that is not dirty.
    public func load(create: Bool) {
        if !fileManager.fileExists(atPath: folder.path), create {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        notes = notes.filter { dirty.contains($0.key) }
        fingerprints = fingerprints.filter { dirty.contains($0.key) }
        provisional = provisional.intersection(dirty)
        outsideEdits = [:]
        rescan(announce: false)
        onEvent(.reloaded)
    }

    /// Switches to another folder: unsaved edits are saved to the old one
    /// first, then the new one is read. Files are never moved.
    public func switchFolder(to url: URL, create: Bool) {
        saveAll()
        folder = url
        dirty = []
        notes = [:]
        fingerprints = [:]
        provisional = []
        outsideEdits = [:]
        load(create: create)
    }

    /// Reconciles memory with the folder: files added, changed or removed
    /// outside the app. Called by the watcher and when the app activates.
    public func rescan() {
        rescan(announce: true)
    }

    private func rescan(announce: Bool) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if !folderIsMissing || !announce {
                folderIsMissing = true
                onEvent(.folderMissing)
            }
            return
        }
        folderIsMissing = false
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var seen: Set<NoteID> = []
        var updated: [NoteID] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let id = NoteID(url.deletingPathExtension().lastPathComponent)
            seen.insert(id)
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate ?? .distantPast
            if let known = fingerprints[id], known.size == size, known.modified == modified { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hash = Self.hash(contents)
            if let known = fingerprints[id], known.hash == hash {
                // Touched, not changed (a sync tool, a copy): remember the new stamp.
                fingerprints[id] = Fingerprint(size: size, modified: modified, hash: hash)
                continue
            }
            fingerprints[id] = Fingerprint(size: size, modified: modified, hash: hash)
            if dirty.contains(id) {
                // Ours is newer in the user's hands: theirs waits for the conflict copy.
                outsideEdits[id] = contents
                continue
            }
            notes[id] = Self.parse(id: id, contents: contents, fileDate: modified, fallbackCreated: modified)
            updated.append(id)
        }
        var removed: [NoteID] = []
        for id in notes.keys where !seen.contains(id) && !dirty.contains(id) && !provisional.contains(id) {
            notes[id] = nil
            fingerprints[id] = nil
            removed.append(id)
        }
        // A dirty note whose file went away is written again on the next save.
        for id in fingerprints.keys where !seen.contains(id) { fingerprints[id] = nil }
        if announce {
            if !updated.isEmpty { onEvent(.updated(updated.sorted())) }
            if !removed.isEmpty { onEvent(.removed(removed.sorted())) }
        }
    }

    // MARK: - Writing

    /// A new note, top of the deck, not yet on disk: the file appears with
    /// the first save (250 ms after the first keystroke) under a provisional
    /// name, and takes the title's name when the note first closes
    /// (`finishProvisional`). Refused while read-only.
    public func create(color: NoteColor, face: NoteFace) throws -> Note {
        guard !readOnly else { throw StoreError.readOnly }
        guard !folderIsMissing else { throw StoreError.folderMissing(folder) }
        let created = now()
        let id = NoteFileName.id(for: "", created: created) { self.notes[$0] != nil || self.fileManager.fileExists(atPath: self.fileURL(for: $0).path) }
        let lowest = notes.values.filter { !$0.archived }.map(\.order).min() ?? 1
        let note = Note(id: id, text: "", color: color, face: face, order: lowest - 1, created: created)
        notes[id] = note
        provisional.insert(id)
        dirty.insert(id)
        onEvent(.updated([id]))
        return note
    }

    /// The text as the user has it now; the app saves it after the debounce.
    public func setText(_ text: String, for id: NoteID) throws {
        guard !readOnly else { throw StoreError.readOnly }
        guard var note = notes[id] else { throw StoreError.noSuchNote(id) }
        guard note.text != text else { return }
        note.text = text
        note.modified = now()
        notes[id] = note
        dirty.insert(id)
    }

    public func setColor(_ color: NoteColor, for id: NoteID) throws {
        try change(id) { $0.color = color }
    }

    public func setFace(_ face: NoteFace, for id: NoteID) throws {
        try change(id) { $0.face = face }
    }

    public func setPinned(_ pinned: Bool, for id: NoteID) throws {
        try change(id) { $0.pinned = pinned }
    }

    /// Out of the deck, into the folder's Archived view; the file stays.
    /// Allowed while read-only (nothing the user wrote changes).
    public func archive(_ id: NoteID) throws {
        try change(id, whileReadOnly: true) { $0.archived = true }
    }

    public func unarchive(_ id: NoteID) throws {
        try change(id, whileReadOnly: true) { $0.archived = false }
    }

    /// The active notes in this order; `order` is rewritten for every note
    /// whose position changed. Pinned notes keep coming first whatever the
    /// order asked for. Allowed while read-only.
    public func reorder(_ ids: [NoteID]) throws {
        var position = 0
        var changed: [NoteID] = []
        for id in ids {
            guard var note = notes[id], !note.archived else { continue }
            if note.order != position {
                note.order = position
                note.modified = now()
                notes[id] = note
                changed.append(id)
            }
            position += 1
        }
        for id in changed { _ = try write(id) }
        if !changed.isEmpty { onEvent(.updated(changed)) }
    }

    private func change(_ id: NoteID, whileReadOnly: Bool = false, _ mutate: (inout Note) -> Void) throws {
        guard !readOnly || whileReadOnly else { throw StoreError.readOnly }
        guard var note = notes[id] else { throw StoreError.noSuchNote(id) }
        mutate(&note)
        note.modified = now()
        notes[id] = note
        // A provisional note that has no file yet keeps its change in memory.
        if provisional.contains(id), fingerprints[id] == nil, note.isEmpty {
            dirty.insert(id)
        } else {
            _ = try write(id)
        }
        onEvent(.updated([id]))
    }

    /// Writes the note if it has unsaved changes. A new note with no text
    /// is not written (Escape on it removes it, `discardIfEmpty`). An
    /// outside edit that landed meanwhile is kept as a conflict copy first.
    @discardableResult
    public func save(_ id: NoteID) throws -> SaveOutcome {
        guard notes[id] != nil else { throw StoreError.noSuchNote(id) }
        guard dirty.contains(id) else { return .unchanged }
        return try write(id)
    }

    /// Every unsaved note; failures are reported per note through `onEvent`
    /// only when the app asks (`save`), so this one swallows them.
    public func saveAll() {
        for id in dirty { _ = try? save(id) }
    }

    /// A new note the user left empty: gone, with its provisional file if
    /// the debounce had written one. The only file removal the app makes,
    /// and only for a file it created seconds ago that holds no text.
    @discardableResult
    public func discardIfEmpty(_ id: NoteID) -> Bool {
        guard let note = notes[id], provisional.contains(id), note.isEmpty else { return false }
        if fingerprints[id] != nil {
            try? fileManager.removeItem(at: fileURL(for: id))
        }
        notes[id] = nil
        fingerprints[id] = nil
        dirty.remove(id)
        provisional.remove(id)
        outsideEdits[id] = nil
        onEvent(.removed([id]))
        return true
    }

    /// A new note closing for the first time: saved, and moved to the file
    /// name its title gives when that name is free. Returns the final id.
    public func finishProvisional(_ id: NoteID) throws -> NoteID {
        guard let note = notes[id] else { throw StoreError.noSuchNote(id) }
        guard provisional.contains(id) else { return id }
        _ = try save(id)
        provisional.remove(id)
        guard fingerprints[id] != nil else { return id }
        let wanted = NoteFileName.id(for: note.title, created: note.created) { candidate in
            candidate != id && (self.notes[candidate] != nil || self.fileManager.fileExists(atPath: self.fileURL(for: candidate).path))
        }
        guard wanted != id, !wanted.rawValue.hasPrefix("note-") else { return id }
        do {
            try fileManager.moveItem(at: fileURL(for: id), to: fileURL(for: wanted))
        } catch {
            return id
        }
        var moved = note
        moved.id = wanted
        notes[id] = nil
        notes[wanted] = moved
        fingerprints[wanted] = fingerprints.removeValue(forKey: id)
        if let values = try? fileURL(for: wanted).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            fingerprints[wanted]?.modified = values.contentModificationDate ?? fingerprints[wanted]?.modified ?? .distantPast
            fingerprints[wanted]?.size = values.fileSize ?? fingerprints[wanted]?.size ?? 0
        }
        onEvent(.renamed(from: id, to: wanted))
        return wanted
    }

    private func write(_ id: NoteID) throws -> SaveOutcome {
        guard let note = notes[id] else { throw StoreError.noSuchNote(id) }
        if provisional.contains(id), fingerprints[id] == nil, note.isEmpty { return .notWritten }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            folderIsMissing = true
            onEvent(.folderMissing)
            throw StoreError.folderMissing(folder)
        }
        var conflictCopy: URL?
        if let theirs = outsideEdits[id] {
            let copy = folder.appendingPathComponent(NoteFileName.conflictName(for: id, at: now()), isDirectory: false)
            try Data(theirs.utf8).write(to: copy, options: .atomic)
            outsideEdits[id] = nil
            conflictCopy = copy
        }
        let url = fileURL(for: id)
        let contents = FrontMatter.serialize(note)
        try Data(contents.utf8).write(to: url, options: .atomic)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        fingerprints[id] = Fingerprint(size: values.fileSize ?? contents.utf8.count, modified: values.contentModificationDate ?? now(), hash: Self.hash(contents))
        dirty.remove(id)
        if let conflictCopy {
            onEvent(.conflict(id, copy: conflictCopy))
            return .savedOverConflict(conflictCopy)
        }
        return .saved
    }

    // MARK: - Export

    /// `.md` is the text as saved without the front matter; `.txt` strips
    /// the markers too. Works while read-only.
    public func export(_ id: NoteID, as format: ExportFormat) throws -> (name: String, data: Data) {
        guard let note = notes[id] else { throw StoreError.noSuchNote(id) }
        return Export.file(for: note, as: format)
    }

    // MARK: - Parsing

    static func parse(id: NoteID, contents: String, fileDate: Date, fallbackCreated: Date) -> Note {
        let parsed = FrontMatter.parse(contents)
        var text = parsed.text
        // The blank line serialize() puts after the block is not text.
        if parsed.hadFrontMatter, text.hasPrefix("\n") { text.removeFirst() }
        return Note(
            id: id, text: text, color: parsed.color ?? .coral, face: parsed.face ?? .sans,
            pinned: parsed.pinned ?? false, archived: parsed.archived ?? false, order: parsed.order ?? 0,
            created: parsed.created ?? fallbackCreated, modified: max(parsed.modified ?? fileDate, fileDate)
        )
    }

    private static func hash(_ contents: String) -> Int {
        var hasher = Hasher()
        hasher.combine(contents)
        return hasher.finalize()
    }
}
