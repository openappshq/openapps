import Foundation

/// What the store tells the app after a change it made or found.
nonisolated public enum StoreEvent: Hashable, Sendable {
    /// The folder was (re)read: everything may have changed.
    case reloaded
    /// These notes changed (edited here, or found changed on disk).
    case updated([NoteID])
    /// These files are gone from the folder.
    case removed([NoteID])
    /// A note's identity moved: its file took its final name when it first
    /// closed, or the user's text went to a conflict copy because the
    /// original file was changed outside (the copy is theirs to keep
    /// writing in).
    case renamed(from: NoteID, to: NoteID)
    /// An outside edit reached the file before ours: the file keeps theirs,
    /// ours is the note at `copy` (a `.renamed` event precedes this one).
    case conflict(NoteID, copy: URL)
    /// The chosen folder is not there; nothing is read or written.
    case folderMissing
}

nonisolated public enum StoreError: Error, LocalizedError, Hashable {
    /// The trial ended or a license is needed: creating and editing refused.
    case readOnly
    case folderMissing(URL)
    case noSuchNote(NoteID)
    /// Where the note's file should be there is now something that is not
    /// a regular file (a folder, a link): nothing is written through it.
    case entryChanged(NoteID)
    /// The file is larger than `NoteStore.maximumFileSize`: shown truncated,
    /// never edited or written.
    case oversized(NoteID)
    /// A flush (folder switch, quit) could not save these notes; they stay
    /// unsaved in memory and the operation was not performed.
    case unsaved([NoteID: String])

    public var errorDescription: String? {
        switch self {
        case .readOnly: return "OpenNotes is read-only until it is licensed."
        case .folderMissing(let url): return "Can’t find the notes folder at \(url.path)."
        case .noSuchNote(let id): return "No note named \(id.rawValue)."
        case .entryChanged(let id): return "\(id.fileName) is no longer a file; the note was not written."
        case .oversized(let id): return "\(id.fileName) is too large to edit here."
        case .unsaved(let problems):
            let names = problems.keys.sorted().map(\.fileName).joined(separator: ", ")
            return "Couldn’t save \(names): \(problems.values.sorted().first ?? "")"
        }
    }
}

/// How a save went.
nonisolated public enum SaveOutcome: Hashable, Sendable {
    /// Nothing to write.
    case unchanged
    case saved
    /// The file had been changed outside since it was last read: it keeps
    /// the outside version, and the user's text was written to a new note
    /// beside it (the id given), which is now the one to keep editing.
    case keptAsConflictCopy(NoteID)
    /// A new note with no text was not written.
    case notWritten
}

/// The notes folder: one `.md` file per note, read at launch and whenever
/// the watcher or the app asks (`rescan`), written 250 ms after typing
/// stops and at once for everything else.
///
/// Every write is a transaction against what was last read or written:
/// the file's size, date and content hash are compared right before the
/// replacement, and a file that changed meanwhile is never overwritten —
/// it keeps the outside version and the user's text becomes a conflict
/// copy beside it. Nothing is ever deleted except a provisional empty
/// note's own file, and only while that file still holds exactly what the
/// app wrote (design/products/opennotes.md, "Notes"). Main-actor: the app
/// calls it from its windows; the watcher hops over.
public final class NoteStore {
    /// Files above this are shown truncated and never edited or written.
    /// A sticky is a few kilobytes; a megabyte is somebody's book.
    public static let maximumFileSize = 1_000_000
    /// How much of an oversized file is shown.
    public static let truncatedPreviewSize = 64_000

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
    /// outside edit from our own. Not touched by a rescan while the note is
    /// dirty: the write transaction compares against it.
    private var fingerprints: [NoteID: Fingerprint] = [:]
    /// Notes with in-memory text not yet on disk.
    private var dirty: Set<NoteID> = []
    /// Notes created this session and not yet closed once: their file is
    /// provisional and takes the title's name when they close.
    private var provisional: Set<NoteID> = []

    private struct Fingerprint: Equatable {
        var size: Int
        var modified: Date
        var hash: Int
    }

    /// What is at a note's path right now.
    private enum DiskEntry {
        case absent
        case notRegular
        case unreadable(Fingerprint)
        case file(contents: String, fingerprint: Fingerprint)
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

    /// The notes with unsaved text, for the flush before a quit or a switch.
    public var unsavedNotes: [NoteID] { dirty.sorted() }

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
        rescan(announce: false)
        onEvent(.reloaded)
    }

    /// Switches to another folder: every unsaved note is written to the old
    /// one first, and the switch is refused (`StoreError.unsaved`, nothing
    /// changed) if any of them cannot be. Files are never moved.
    public func switchFolder(to url: URL, create: Bool) throws {
        let problems = saveAll()
        guard problems.isEmpty else { throw StoreError.unsaved(problems) }
        folder = url
        dirty = []
        notes = [:]
        fingerprints = [:]
        provisional = []
        load(create: create)
    }

    /// Reconciles memory with the folder: files added, changed or removed
    /// outside the app. Called by the watcher and when the app activates.
    /// A dirty note is left alone here — its file is compared at the next
    /// write, where an outside change is preserved.
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
            if dirty.contains(id) { continue }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate ?? .distantPast
            if let known = fingerprints[id], known.size == size, known.modified == modified { continue }
            guard case .file(let contents, let fingerprint) = read(url, size: size, modified: modified) else { continue }
            if let known = fingerprints[id], known.hash == fingerprint.hash {
                // Touched, not changed (a sync tool, a copy): remember the new stamp.
                fingerprints[id] = fingerprint
                continue
            }
            fingerprints[id] = fingerprint
            notes[id] = Self.parse(id: id, contents: contents, fileDate: modified, fallbackCreated: modified, truncated: size > Self.maximumFileSize)
            // A provisional note replaced from outside is somebody's note now.
            provisional.remove(id)
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
        let note = Note(id: id, text: "", color: color, face: face, order: nextTopOrder(), created: created)
        notes[id] = note
        provisional.insert(id)
        dirty.insert(id)
        onEvent(.updated([id]))
        return note
    }

    /// One below the lowest active order, so the note lands on top. Orders
    /// are clamped on read, and if the lowest is at the floor anyway the
    /// active notes are renumbered first, so this never overflows.
    private func nextTopOrder() -> Int {
        let lowest = notes.values.filter { !$0.archived }.map(\.order).min() ?? 1
        if lowest > Note.orderRange.lowerBound { return lowest - 1 }
        for (index, note) in active.enumerated() {
            var renumbered = note
            renumbered.order = index
            notes[note.id] = renumbered
            if !dirty.contains(note.id) { dirty.insert(note.id) }
        }
        return -1
    }

    /// The text as the user has it now; the app saves it after the debounce.
    public func setText(_ text: String, for id: NoteID) throws {
        guard !readOnly else { throw StoreError.readOnly }
        guard var note = notes[id] else { throw StoreError.noSuchNote(id) }
        guard !note.truncated else { throw StoreError.oversized(id) }
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
            guard var note = notes[id], !note.archived, !note.truncated else { continue }
            if note.order != position {
                note.order = position
                note.modified = now()
                notes[id] = note
                dirty.insert(id)
                changed.append(id)
            }
            position += 1
        }
        var problems: [NoteID: String] = [:]
        for id in changed {
            do { _ = try write(id) } catch { problems[id] = error.localizedDescription }
        }
        if !changed.isEmpty { onEvent(.updated(changed)) }
        if !problems.isEmpty { throw StoreError.unsaved(problems) }
    }

    private func change(_ id: NoteID, whileReadOnly: Bool = false, _ mutate: (inout Note) -> Void) throws {
        guard !readOnly || whileReadOnly else { throw StoreError.readOnly }
        guard var note = notes[id] else { throw StoreError.noSuchNote(id) }
        guard !note.truncated else { throw StoreError.oversized(id) }
        mutate(&note)
        note.modified = now()
        notes[id] = note
        dirty.insert(id)
        // A provisional note that has no file yet keeps its change in memory.
        if provisional.contains(id), fingerprints[id] == nil, note.isEmpty {
            onEvent(.updated([id]))
            return
        }
        let outcome = try write(id)
        if case .keptAsConflictCopy(let copy) = outcome {
            onEvent(.updated([id, copy]))
        } else {
            onEvent(.updated([id]))
        }
    }

    /// Writes the note if it has unsaved changes. A new note with no text
    /// is not written (Escape on it removes it, `discardIfEmpty`). A file
    /// that changed outside since it was last read is never overwritten:
    /// see `write`. A failed write keeps the note dirty.
    @discardableResult
    public func save(_ id: NoteID) throws -> SaveOutcome {
        guard notes[id] != nil else { throw StoreError.noSuchNote(id) }
        guard dirty.contains(id) else { return .unchanged }
        return try write(id)
    }

    /// Every unsaved note; the ones that could not be written, with why.
    /// They stay dirty.
    @discardableResult
    public func saveAll() -> [NoteID: String] {
        var problems: [NoteID: String] = [:]
        for id in dirty.sorted() {
            do { _ = try save(id) } catch { problems[id] = error.localizedDescription }
        }
        return problems
    }

    /// A new note the user left empty: gone, with its provisional file if
    /// the debounce had written one. The only file removal the app makes,
    /// and only while the file still holds exactly what the app last wrote
    /// (same size, date and content); anything else at that path is left
    /// where it is and the note becomes an ordinary one on the next rescan.
    @discardableResult
    public func discardIfEmpty(_ id: NoteID) -> Bool {
        guard let note = notes[id], provisional.contains(id), note.isEmpty else { return false }
        if let known = fingerprints[id] {
            switch read(fileURL(for: id)) {
            case .file(_, let current) where current == known:
                try? fileManager.removeItem(at: fileURL(for: id))
            case .absent:
                break
            default:
                // Replaced, touched or unreadable: not ours to remove.
                provisional.remove(id)
                dirty.remove(id)
                fingerprints[id] = nil
                notes[id] = nil
                rescan(announce: true)
                return false
            }
        }
        notes[id] = nil
        fingerprints[id] = nil
        dirty.remove(id)
        provisional.remove(id)
        onEvent(.removed([id]))
        return true
    }

    /// A new note closing for the first time: saved, and moved to the file
    /// name its title gives when that name is free and the file is still
    /// the one the app wrote. Returns the id the note has now (a conflict
    /// copy's when the save found an outside edit).
    public func finishProvisional(_ id: NoteID) throws -> NoteID {
        guard notes[id] != nil else { throw StoreError.noSuchNote(id) }
        guard provisional.contains(id) else { return id }
        var current = id
        if case .keptAsConflictCopy(let copy) = try save(id) { current = copy }
        provisional.remove(id)
        provisional.remove(current)
        guard let note = notes[current], let known = fingerprints[current] else { return current }
        let wanted = NoteFileName.id(for: note.title, created: note.created) { candidate in
            candidate != current && (self.notes[candidate] != nil || self.fileManager.fileExists(atPath: self.fileURL(for: candidate).path))
        }
        guard wanted != current, !wanted.rawValue.hasPrefix("note-") else { return current }
        // Only the file the app wrote is renamed; anything changed meanwhile
        // waits for the next write transaction.
        guard case .file(_, let onDisk) = read(fileURL(for: current)), onDisk == known else { return current }
        do {
            try fileManager.moveItem(at: fileURL(for: current), to: fileURL(for: wanted))
        } catch {
            return current
        }
        var moved = note
        moved.id = wanted
        notes[current] = nil
        notes[wanted] = moved
        fingerprints[wanted] = fingerprints.removeValue(forKey: current)
        if let values = try? fileURL(for: wanted).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            fingerprints[wanted]?.modified = values.contentModificationDate ?? fingerprints[wanted]?.modified ?? .distantPast
            fingerprints[wanted]?.size = values.fileSize ?? fingerprints[wanted]?.size ?? 0
        }
        onEvent(.renamed(from: current, to: wanted))
        return wanted
    }

    /// The write transaction. The entry at the note's path is compared with
    /// what was last read or written:
    /// - absent: written (a first write, or a file removed outside);
    /// - the same file (size, date, or content hash): replaced atomically;
    /// - changed outside: left alone; the user's text goes to a new note
    ///   beside it under a unique conflict name, the outside version is
    ///   read back under the original id, and `.keptAsConflictCopy` names
    ///   the copy (a provisional note that never reached disk simply moves
    ///   to the next free provisional name);
    /// - not a regular file, or the file unreadable: refused
    ///   (`entryChanged`); the note stays dirty.
    private func write(_ id: NoteID) throws -> SaveOutcome {
        guard let note = notes[id] else { throw StoreError.noSuchNote(id) }
        if note.truncated { throw StoreError.oversized(id) }
        if provisional.contains(id), fingerprints[id] == nil, note.isEmpty { return .notWritten }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            folderIsMissing = true
            onEvent(.folderMissing)
            throw StoreError.folderMissing(folder)
        }
        let url = fileURL(for: id)
        let known = fingerprints[id]
        switch read(url) {
        case .absent:
            break
        case .notRegular:
            throw StoreError.entryChanged(id)
        case .unreadable(let onDisk):
            // Ours cannot replace what cannot be read; it goes beside it.
            if let known, onDisk == known { break }
            return try divert(id, note: note, theirs: nil)
        case .file(let contents, let onDisk):
            if let known, onDisk == known || onDisk.hash == known.hash { break }
            return try divert(id, note: note, theirs: contents)
        }
        try replace(url, with: note, id: id)
        return .saved
    }

    /// Ours to a new note beside the original; theirs read back.
    private func divert(_ id: NoteID, note: Note, theirs: String?) throws -> SaveOutcome {
        let wasProvisional = provisional.contains(id) && fingerprints[id] == nil
        let copyID: NoteID
        if wasProvisional {
            copyID = NoteFileName.id(for: "", created: note.created) { candidate in
                candidate == id || self.notes[candidate] != nil || self.fileManager.fileExists(atPath: self.fileURL(for: candidate).path)
            }
        } else {
            copyID = try reserveConflictName(for: id)
        }
        var copy = note
        copy.id = copyID
        notes[copyID] = copy
        dirty.insert(copyID)
        if wasProvisional { provisional.insert(copyID) }
        provisional.remove(id)
        dirty.remove(id)
        fingerprints[id] = nil
        if let theirs, let values = try? fileURL(for: id).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let modified = values.contentModificationDate ?? now()
            let size = values.fileSize ?? theirs.utf8.count
            fingerprints[id] = Fingerprint(size: size, modified: modified, hash: Self.hash(theirs))
            notes[id] = Self.parse(id: id, contents: theirs, fileDate: modified, fallbackCreated: modified, truncated: size > Self.maximumFileSize)
        } else {
            notes[id] = nil
        }
        do {
            try replace(fileURL(for: copyID), with: copy, id: copyID)
        } catch {
            // Ours is still in memory under the new id, dirty; the next save retries.
            onEvent(.renamed(from: id, to: copyID))
            throw error
        }
        onEvent(.renamed(from: id, to: copyID))
        if !wasProvisional { onEvent(.conflict(id, copy: fileURL(for: copyID))) }
        return .keptAsConflictCopy(copyID)
    }

    /// `<name> (conflict <time>).md`, then `-2`, `-3`… — a name nothing else
    /// holds, reserved by creating the file without overwriting.
    private func reserveConflictName(for id: NoteID) throws -> NoteID {
        let base = NoteFileName.conflictStem(for: id, at: now())
        var candidate = NoteID(base)
        var counter = 2
        while true {
            if notes[candidate] == nil {
                do {
                    try Data().write(to: fileURL(for: candidate), options: .withoutOverwriting)
                    return candidate
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // Taken: the next suffix.
                }
            }
            candidate = NoteID("\(base)-\(counter)")
            counter += 1
            if counter > 1000 { throw StoreError.entryChanged(id) }
        }
    }

    private func replace(_ url: URL, with note: Note, id: NoteID) throws {
        let contents = FrontMatter.serialize(note)
        try Data(contents.utf8).write(to: url, options: .atomic)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        fingerprints[id] = Fingerprint(size: values.fileSize ?? contents.utf8.count, modified: values.contentModificationDate ?? now(), hash: Self.hash(contents))
        dirty.remove(id)
    }

    // MARK: - Disk

    private func read(_ url: URL) -> DiskEntry {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return .absent }
        guard values.isRegularFile == true else { return .notRegular }
        return read(url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
    }

    /// Reads at most `maximumFileSize` bytes; a larger file is read to
    /// `truncatedPreviewSize` and its fingerprint covers what was read.
    private func read(_ url: URL, size: Int, modified: Date) -> DiskEntry {
        let limit = size > Self.maximumFileSize ? Self.truncatedPreviewSize : Self.maximumFileSize
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable(Fingerprint(size: size, modified: modified, hash: 0)) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return .unreadable(Fingerprint(size: size, modified: modified, hash: 0)) }
        guard let contents = Self.decode(data, truncated: size > limit) else { return .unreadable(Fingerprint(size: size, modified: modified, hash: 0)) }
        return .file(contents: contents, fingerprint: Fingerprint(size: size, modified: modified, hash: Self.hash(contents)))
    }

    /// UTF-8, or nil; a truncated read drops a split character at the end.
    private static func decode(_ data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        var bytes = data
        for _ in 0..<3 {
            bytes.removeLast()
            if let text = String(data: bytes, encoding: .utf8) { return text }
        }
        return nil
    }

    // MARK: - Export

    /// `.md` is the text as saved without the front matter; `.txt` strips
    /// the markers too. Works while read-only.
    public func export(_ id: NoteID, as format: ExportFormat) throws -> (name: String, data: Data) {
        guard let note = notes[id] else { throw StoreError.noSuchNote(id) }
        return Export.file(for: note, as: format)
    }

    // MARK: - Parsing

    static func parse(id: NoteID, contents: String, fileDate: Date, fallbackCreated: Date, truncated: Bool = false) -> Note {
        let parsed = FrontMatter.parse(contents)
        var text = parsed.text
        // The blank line serialize() puts after the block is not text.
        if parsed.hadFrontMatter, text.hasPrefix("\n") { text.removeFirst() }
        var note = Note(
            id: id, text: text, color: parsed.color ?? .coral, face: parsed.face ?? .sans,
            pinned: parsed.pinned ?? false, archived: parsed.archived ?? false, order: Note.clampOrder(parsed.order ?? 0),
            created: parsed.created ?? fallbackCreated, modified: max(parsed.modified ?? fileDate, fileDate)
        )
        note.truncated = truncated
        return note
    }

    private static func hash(_ contents: String) -> Int {
        var hasher = Hasher()
        hasher.combine(contents)
        return hasher.finalize()
    }
}
