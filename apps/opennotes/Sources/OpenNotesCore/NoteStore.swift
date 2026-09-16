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
    /// A write ended in a state the store could not settle cleanly (a
    /// rename the system refused mid-transaction): nothing was deleted,
    /// every version is on disk under some name, and the message says
    /// where; the note is written again only once the next rescan has
    /// re-read it.
    case storageProblem(String)
}

nonisolated public enum StoreError: Error, LocalizedError, Hashable {
    /// The trial ended or a license is needed: every change refused.
    case readOnly
    case folderMissing(URL)
    case noSuchNote(NoteID)
    /// Where the note's file should be there is now something that is not
    /// a regular file (a folder, a link): nothing is written through it.
    case entryChanged(NoteID)
    /// The file is larger than `NoteStore.maximumFileSize`: shown truncated,
    /// never edited or written.
    case oversized(NoteID)
    /// The note's body is not in memory and could not be read back (the
    /// file is missing or unreadable right now): what is shown is the
    /// summary, and it is never edited or written as if it were the text.
    case bodyUnavailable(NoteID)
    /// A flush (folder switch, quit) could not save these notes; they stay
    /// unsaved in memory and the operation was not performed.
    case unsaved([NoteID: String])
    /// The system refused a file operation; the message names it.
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly: return "OpenNotes is read-only until it is licensed."
        case .folderMissing(let url): return "Can’t find the notes folder at \(url.path)."
        case .noSuchNote(let id): return "No note named \(id.rawValue)."
        case .entryChanged(let id): return "\(id.fileName) is no longer a file; the note was not written."
        case .oversized(let id): return "\(id.fileName) is too large to edit here."
        case .bodyUnavailable(let id): return "Can’t read \(id.fileName) right now; shown in part."
        case .unsaved(let problems):
            let names = problems.keys.sorted().map(\.fileName).joined(separator: ", ")
            return "Couldn’t save \(names): \(problems.values.sorted().first ?? "")"
        case .io(let message): return message
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

#if DEBUG
/// Points inside the store's transactions where a test can interleave an
/// outside writer deterministically. Debug builds only: a release binary
/// carries neither the seam nor its names (verify-release.sh checks).
nonisolated public enum StoreInterleaving: Hashable, Sendable {
    /// The existing file has been verified through its descriptor; the
    /// replacement is about to be swapped in.
    case beforeReplace(NoteID)
    /// The provisional file has been verified through its descriptor; the
    /// name is about to be unlinked.
    case beforeUnlink(NoteID)
    /// The destination was found absent; the exclusive create is next.
    case beforeCreate(NoteID)
}
#endif

/// The notes folder: one `.md` file per note, read at launch and whenever
/// the watcher or the app asks (`rescan`), written 250 ms after typing
/// stops and at once for everything else.
///
/// Every write is a transaction: the existing file is opened (never
/// through a link), hashed in full through that descriptor and compared
/// with what was last read or written; the replacement is exclusively
/// created when the file is absent, or swapped in atomically and the
/// displaced file checked to be the very inode that was verified — an
/// outside edit that lands at any point is never lost: the file keeps it
/// and the user's text becomes a new note beside it. The only removal the
/// store makes is a provisional empty note's own file, unlinked by name
/// only after the file open under that name proved to be the one the app
/// wrote (design/products/opennotes.md, "Notes").
///
/// Memory is bounded twice: a file is read up to `maximumFileSize` (a
/// larger one is shown truncated and read-only), and note bodies are kept
/// under `bodyBudget` bytes in total — beyond it the least recently used
/// bodies fall back to a summary (the first kilobyte, enough for the title
/// and the list) and are read again on demand; dirty and retained (open)
/// notes are never evicted. Main-actor: the app calls it from its windows;
/// the watcher hops over.
public final class NoteStore {
    /// Files above this are shown truncated and never edited or written.
    /// A sticky is a few kilobytes; a megabyte is somebody's book.
    public static let maximumFileSize = 1_000_000
    /// How much of an oversized file is shown.
    public static let truncatedPreviewSize = 64_000
    /// The default budget for retained bodies, all notes together.
    public static let defaultBodyBudget = 8_000_000
    /// What an evicted note keeps: enough for the title and the first lines.
    public static let summarySize = 1_024

    public private(set) var folder: URL
    public private(set) var notes: [NoteID: Note] = [:]
    /// The folder could not be found on the last read or write.
    public private(set) var folderIsMissing = false
    /// Whether the store may change anything right now: asked afresh at
    /// every mutation and again at the file boundary (`write`), never
    /// stored. The app binds the license's projected access (LICENSING.md);
    /// a build without licensing, and a store on its own, is always allowed.
    public var access: () -> Bool = { true }
    /// The trial ended or a license is needed: creating, editing, renaming,
    /// archiving, unarchiving and reordering are refused and no file is
    /// written or removed — except the flush of text the user typed while
    /// it was allowed (`accepted`), which is never lost. Reading,
    /// rescanning and exporting still work. Derived from `access` at the
    /// moment it is read.
    public var readOnly: Bool { !access() }
    public var onEvent: (StoreEvent) -> Void = { _ in }
    #if DEBUG
    /// Tests only: an outside writer run at a chosen point of a transaction.
    public var interleavingHook: ((StoreInterleaving) -> Void)?
    #endif
    /// The budget for retained bodies, in bytes of UTF-8.
    public let bodyBudget: Int
    /// Bytes of full bodies held right now.
    public private(set) var retainedBodyBytes = 0

    private let fileManager: FileManager
    private let now: () -> Date
    /// What the file held when it was last read or written, to tell an
    /// outside edit from our own. Not touched by a rescan while the note is
    /// dirty: the write transaction compares against it.
    private var identities: [NoteID: NoteFile.Identity] = [:]
    /// Notes with in-memory text not yet on disk.
    private var dirty: Set<NoteID> = []
    /// Dirty notes whose text was accepted while writing was allowed (every
    /// keystroke asks; a refused one never reaches the buffer): the stamp
    /// that lets `write` flush them after a deadline — on the debounce, a
    /// close, sleep or quit — so nothing typed under access is lost. The
    /// restriction applies to new edits only. Cleared by the write.
    private var accepted: Set<NoteID> = []
    /// Notes created this session and not yet closed once: their file is
    /// provisional and takes the title's name when they close.
    private var provisional: Set<NoteID> = []
    /// Notes whose full body is in memory, least recently used first.
    private var loaded: [NoteID] = []
    /// Notes the app holds open: never evicted.
    private var retained: [NoteID: Int] = [:]

    public init(folder: URL, fileManager: FileManager = .default, bodyBudget: Int = NoteStore.defaultBodyBudget, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.fileManager = fileManager
        self.bodyBudget = max(bodyBudget, Self.maximumFileSize)
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

    /// The note with its full body in memory (read from disk if it had
    /// been evicted), moved to the front of the budget's line. When the
    /// read fails the note comes back as it is, with `bodyIsLoaded` false
    /// and the summary as its text: shown in part, never editable, and
    /// asked again on the next call (the next render, keystroke or rescan).
    public func body(of id: NoteID) -> Note? {
        guard var note = notes[id] else { return nil }
        if !note.bodyIsLoaded {
            guard case .file(let fd, let info) = NoteFile.open(fileURL(for: id)) else { return note }
            defer { NoteFile.close(fd) }
            guard let contents = NoteFile.read(fd: fd, stat: info, cap: Self.readCap(for: info)), let text = contents.text else { return note }
            let fresh = Self.parse(id: id, contents: text, fileDate: contents.identity.modified, fallbackCreated: contents.identity.modified, truncated: contents.truncated)
            note.text = fresh.text
            note.truncated = fresh.truncated
            note.bodyIsLoaded = true
            identities[id] = contents.identity
            // Room first (this note is not in the line yet, so it cannot be
            // the one evicted), then the body is accounted for.
            enforceBudget(toFit: note.text.utf8.count)
            notes[id] = note
            account(id, bytes: note.text.utf8.count)
        }
        touch(id)
        return note
    }

    /// The app holds the note open: its body stays whatever the budget.
    public func retain(_ id: NoteID) {
        retained[id, default: 0] += 1
        _ = body(of: id)
    }

    public func release(_ id: NoteID) {
        guard let count = retained[id] else { return }
        if count <= 1 { retained[id] = nil } else { retained[id] = count - 1 }
        enforceBudget()
    }

    /// Search over titles and text, case- and diacritic-insensitive,
    /// every word somewhere in the note. Evicted bodies are read one at
    /// a time and not retained.
    public func search(_ query: String, archived: Bool) -> [Note] {
        let candidates = archived ? self.archived : active
        let words = query.split(whereSeparator: \.isWhitespace).map { Search.fold(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return candidates }
        return candidates.filter { note in
            let text: String
            if note.bodyIsLoaded {
                text = note.text
            } else if case .file(let fd, let info) = NoteFile.open(fileURL(for: note.id)) {
                defer { NoteFile.close(fd) }
                text = NoteFile.read(fd: fd, stat: info, cap: Self.readCap(for: info))?.text ?? note.text
            } else {
                text = note.text
            }
            let haystack = Search.fold(text)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Reads the folder, creating it when `create` (the default folder is
    /// always created; a chosen one never is). Replaces everything in
    /// memory that is not dirty.
    public func load(create: Bool) {
        if !fileManager.fileExists(atPath: folder.path), create {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        notes = notes.filter { dirty.contains($0.key) }
        identities = identities.filter { dirty.contains($0.key) }
        provisional = provisional.intersection(dirty)
        loaded = loaded.filter { dirty.contains($0) }
        retainedBodyBytes = loaded.reduce(0) { $0 + (notes[$1]?.text.utf8.count ?? 0) }
        accepted = accepted.intersection(dirty)
        rescan(announce: false)
        onEvent(.reloaded)
    }

    /// Switches to another folder: every unsaved note is written to the old
    /// one first, and the switch is refused (`StoreError.unsaved`, nothing
    /// changed) if any of them cannot be. Files are never moved.
    public func switchFolder(to url: URL, create: Bool) throws {
        // A folder change is a mutation the license decides (the app asks
        // before the panel and after it; this is the last word).
        guard !readOnly else { throw StoreError.readOnly }
        let problems = saveAll()
        guard problems.isEmpty else { throw StoreError.unsaved(problems) }
        folder = url
        dirty = []
        accepted = []
        notes = [:]
        identities = [:]
        provisional = []
        loaded = []
        retained = [:]
        retainedBodyBytes = 0
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
        recoverStrandedTemporaries()
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var seen: Set<NoteID> = []
        var updated: [NoteID] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            let id = NoteID(url.deletingPathExtension().lastPathComponent)
            guard case .file(let fd, let info) = NoteFile.open(url) else { continue }
            seen.insert(id)
            if dirty.contains(id) {
                NoteFile.close(fd)
                continue
            }
            // Same inode, size and date as last time: unchanged, no read.
            if let known = identities[id], known.device == info.st_dev, known.inode == info.st_ino,
               known.size == Int(info.st_size), known.modified == NoteFile.date(info.st_mtimespec) {
                NoteFile.close(fd)
                continue
            }
            let contents = NoteFile.read(fd: fd, stat: info, cap: Self.readCap(for: info))
            NoteFile.close(fd)
            guard let contents, let text = contents.text else { continue }
            if let known = identities[id], known.hash == contents.identity.hash, known.size == contents.identity.size {
                // Touched, not changed (a sync tool, a copy): remember the new stamp.
                identities[id] = contents.identity
                continue
            }
            identities[id] = contents.identity
            store(Self.parse(id: id, contents: text, fileDate: contents.identity.modified, fallbackCreated: contents.identity.modified, truncated: contents.truncated))
            // A provisional note replaced from outside is somebody's note now.
            provisional.remove(id)
            updated.append(id)
        }
        var removed: [NoteID] = []
        for id in notes.keys where !seen.contains(id) && !dirty.contains(id) && !provisional.contains(id) {
            forget(id)
            removed.append(id)
        }
        // A dirty note whose file went away is written again on the next save.
        for id in identities.keys where !seen.contains(id) { identities[id] = nil }
        if announce {
            if !updated.isEmpty { onEvent(.updated(updated.sorted())) }
            if !removed.isEmpty { onEvent(.removed(removed.sorted())) }
        }
    }

    /// A file over the maximum is read to the preview size only; the hash
    /// still covers every byte.
    private static func readCap(for info: stat) -> Int {
        Int(info.st_size) > maximumFileSize ? truncatedPreviewSize : maximumFileSize
    }

    /// A hidden `.<name>.md.tmp-<uuid>` left by a write the system cut
    /// short holds a version nothing else has: it gets a visible name,
    /// `<name> (recovered <time>).md`, never over an existing file, and
    /// is read as a note like any other. One that cannot be moved stays.
    private func recoverStrandedTemporaries() {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.contains(".md.tmp-") {
            guard let range = name.range(of: ".md.tmp-") else { continue }
            let stem = String(name[name.index(after: name.startIndex)..<range.lowerBound])
            let base = NoteFileName.recoveredStem(for: stem, at: now())
            var candidate = base
            var counter = 2
            while counter < 1000 {
                do {
                    try NoteFile.moveExclusively(folder.appendingPathComponent(name), to: folder.appendingPathComponent(candidate + ".md"))
                    break
                } catch NoteFile.Failure.exists {
                    candidate = "\(base)-\(counter)"
                    counter += 1
                } catch {
                    break
                }
            }
        }
    }

    // MARK: - The body budget

    /// Puts a freshly parsed note in memory: with its body while the budget
    /// allows, as a summary otherwise.
    private func store(_ note: Note) {
        var note = note
        if let old = notes[note.id], old.bodyIsLoaded { unaccount(note.id) }
        let bytes = note.text.utf8.count
        if retainedBodyBytes + bytes <= bodyBudget || retained[note.id] != nil || dirty.contains(note.id) {
            note.bodyIsLoaded = true
            notes[note.id] = note
            account(note.id, bytes: bytes)
            enforceBudget()
        } else {
            enforceBudget(toFit: bytes)
            if retainedBodyBytes + bytes <= bodyBudget {
                note.bodyIsLoaded = true
                notes[note.id] = note
                account(note.id, bytes: bytes)
            } else {
                note.text = Self.summary(of: note.text)
                note.bodyIsLoaded = false
                notes[note.id] = note
            }
        }
    }

    private func forget(_ id: NoteID) {
        if notes[id]?.bodyIsLoaded == true { unaccount(id) }
        notes[id] = nil
        identities[id] = nil
        retained[id] = nil
    }

    private func account(_ id: NoteID, bytes: Int) {
        loaded.removeAll { $0 == id }
        loaded.append(id)
        retainedBodyBytes += bytes
    }

    private func unaccount(_ id: NoteID) {
        guard let index = loaded.firstIndex(of: id) else { return }
        loaded.remove(at: index)
        retainedBodyBytes -= notes[id]?.text.utf8.count ?? 0
    }

    private func touch(_ id: NoteID) {
        guard let index = loaded.firstIndex(of: id) else { return }
        loaded.remove(at: index)
        loaded.append(id)
    }

    /// Evicts least recently used bodies (never dirty or retained ones)
    /// until the budget, less `room`, holds.
    private func enforceBudget(toFit room: Int = 0) {
        var index = 0
        while retainedBodyBytes + room > bodyBudget, index < loaded.count {
            let id = loaded[index]
            if dirty.contains(id) || retained[id] != nil {
                index += 1
                continue
            }
            guard var note = notes[id] else { loaded.remove(at: index); continue }
            loaded.remove(at: index)
            retainedBodyBytes -= note.text.utf8.count
            note.text = Self.summary(of: note.text)
            note.bodyIsLoaded = false
            notes[id] = note
        }
    }

    /// The first kilobyte, cut at a character boundary.
    static func summary(of text: String) -> String {
        guard text.utf8.count > summarySize else { return text }
        var length = summarySize
        while length > 0 {
            if let prefix = String(text.utf8.prefix(length)) { return prefix }
            length -= 1
        }
        return ""
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
        var note = Note(id: id, text: "", color: color, face: face, order: nextTopOrder(), created: created)
        note.bodyIsLoaded = true
        notes[id] = note
        account(id, bytes: 0)
        provisional.insert(id)
        dirty.insert(id)
        onEvent(.updated([id]))
        return note
    }

    /// The app's own note (`WelcomeNote`), written whole and at once: the
    /// file is created exclusively — never over one that appeared meanwhile
    /// — and the note is in memory, clean, as if read. The license is not
    /// asked: this runs on the launch that first reads the folder, before
    /// an official build's storage has answered, and only on a fresh
    /// install (the app's caller decides), which is always in its trial.
    public func plant(_ note: Note) throws {
        guard !folderIsMissing else { throw StoreError.folderMissing(folder) }
        guard notes[note.id] == nil else { throw StoreError.io("\(note.id.fileName) is already there.") }
        do {
            identities[note.id] = try NoteFile.createExclusively(fileURL(for: note.id), contents: FrontMatter.serialize(note))
        } catch NoteFile.Failure.exists {
            throw StoreError.io("\(note.id.fileName) is already there.")
        } catch {
            throw StoreError.io("\(note.id.fileName): \(error)")
        }
        var planted = note
        planted.bodyIsLoaded = true
        planted.truncated = false
        store(planted)
        onEvent(.updated([note.id]))
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
    /// Refused while read-only; accepted, the buffer is stamped as typed
    /// under access, so its flush is allowed whatever the license says then.
    /// The edit must start from a body that is in memory: a note whose
    /// body is not loaded (an evicted body the disk would not give back)
    /// is refused, never read back here — an editor holding the summary
    /// would otherwise replace the whole file with it.
    public func setText(_ text: String, for id: NoteID) throws {
        guard !readOnly else { throw StoreError.readOnly }
        guard var note = notes[id] else { throw StoreError.noSuchNote(id) }
        guard note.bodyIsLoaded else { throw StoreError.bodyUnavailable(id) }
        guard !note.truncated else { throw StoreError.oversized(id) }
        guard note.text != text else { return }
        unaccount(id)
        note.text = text
        note.modified = now()
        note.bodyIsLoaded = true
        notes[id] = note
        account(id, bytes: text.utf8.count)
        dirty.insert(id)
        accepted.insert(id)
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
    /// Refused while read-only: the flag is written to the file.
    public func archive(_ id: NoteID) throws {
        try change(id) { $0.archived = true }
    }

    public func unarchive(_ id: NoteID) throws {
        try change(id) { $0.archived = false }
    }

    /// The active notes in this order; `order` is rewritten for every note
    /// whose position changed. Pinned notes keep coming first whatever the
    /// order asked for. Refused while read-only.
    public func reorder(_ ids: [NoteID]) throws {
        guard !readOnly else { throw StoreError.readOnly }
        var position = 0
        var changed: [NoteID] = []
        for id in ids {
            guard let existing = notes[id], !existing.archived, !existing.truncated else { continue }
            if existing.order != position {
                guard var note = body(of: id) else { continue }
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

    private func change(_ id: NoteID, _ mutate: (inout Note) -> Void) throws {
        guard !readOnly else { throw StoreError.readOnly }
        guard notes[id] != nil else { throw StoreError.noSuchNote(id) }
        guard var note = body(of: id), note.bodyIsLoaded else { throw StoreError.bodyUnavailable(id) }
        guard !note.truncated else { throw StoreError.oversized(id) }
        mutate(&note)
        note.modified = now()
        notes[id] = note
        dirty.insert(id)
        // A provisional note that has no file yet keeps its change in memory.
        if provisional.contains(id), identities[id] == nil, note.isEmpty {
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
    /// see `write`. A failed write keeps the note dirty. While read-only
    /// only a buffer stamped `accepted` (text typed while it was allowed)
    /// is written; any other pending change is refused before the
    /// transaction and stays in memory until writing is allowed.
    @discardableResult
    public func save(_ id: NoteID) throws -> SaveOutcome {
        guard notes[id] != nil else { throw StoreError.noSuchNote(id) }
        guard dirty.contains(id) else { return .unchanged }
        return try write(id)
    }

    /// Every unsaved note; the ones that could not be written, with why.
    /// They stay dirty. A note the license refuses (a pending change that
    /// is not accepted text) is skipped silently, not reported: it is no
    /// failure, and quit is never held by the license (LICENSING.md).
    @discardableResult
    public func saveAll() -> [NoteID: String] {
        var problems: [NoteID: String] = [:]
        for id in dirty.sorted() {
            do {
                _ = try save(id)
            } catch StoreError.readOnly {
                continue
            } catch {
                problems[id] = error.localizedDescription
            }
        }
        return problems
    }

    /// A new note the user left empty: gone, with its provisional file if
    /// the debounce had written one. The only file removal the app makes:
    /// the entry under the provisional name is opened (never through a
    /// link), must be a regular file on the very inode the app wrote, with
    /// the very content, and only then is the name unlinked — never
    /// recursively, and anything else at that path is left where it is.
    /// While read-only a file is never removed: a note whose file exists
    /// stays (as "Untitled"); one that was never written is only forgotten.
    @discardableResult
    public func discardIfEmpty(_ id: NoteID) -> Bool {
        guard let note = notes[id], provisional.contains(id), note.isEmpty else { return false }
        if let known = identities[id] {
            guard !readOnly else { return false }
            switch NoteFile.open(fileURL(for: id)) {
            case .absent:
                break
            case .notRegular:
                return keepAsForeign(id)
            case .file(let fd, let info):
                defer { NoteFile.close(fd) }
                guard (info.st_dev, info.st_ino) == known.sameInode,
                      let contents = NoteFile.read(fd: fd, stat: info, cap: Self.readCap(for: info)),
                      contents.identity.hash == known.hash, contents.identity.size == known.size else {
                    return keepAsForeign(id)
                }
                #if DEBUG
                interleavingHook?(.beforeUnlink(id))
                #endif
                guard (try? NoteFile.unlink(fileURL(for: id), verified: fd)) != nil else { return keepAsForeign(id) }
            }
        }
        forget(id)
        dirty.remove(id)
        accepted.remove(id)
        provisional.remove(id)
        onEvent(.removed([id]))
        return true
    }

    /// Whatever is under a provisional name is not ours to remove: the note
    /// leaves memory and the next rescan reads what is there.
    private func keepAsForeign(_ id: NoteID) -> Bool {
        provisional.remove(id)
        dirty.remove(id)
        accepted.remove(id)
        forget(id)
        rescan(announce: true)
        return false
    }

    /// A new note closing for the first time: saved, and moved to the file
    /// name its title gives when that name is free and the file is still
    /// the one the app wrote. Returns the id the note has now (a conflict
    /// copy's when the save found an outside edit). Refused while read-only
    /// (the rename is a file change): the note stays provisional and is
    /// named when it next closes allowed.
    public func finishProvisional(_ id: NoteID) throws -> NoteID {
        guard notes[id] != nil else { throw StoreError.noSuchNote(id) }
        guard provisional.contains(id) else { return id }
        guard !readOnly else { throw StoreError.readOnly }
        var current = id
        if case .keptAsConflictCopy(let copy) = try save(id) { current = copy }
        provisional.remove(id)
        provisional.remove(current)
        guard let note = notes[current], let known = identities[current] else { return current }
        let wanted = NoteFileName.id(for: note.title, created: note.created) { candidate in
            candidate != current && (self.notes[candidate] != nil || self.fileManager.fileExists(atPath: self.fileURL(for: candidate).path))
        }
        guard wanted != current, !wanted.rawValue.hasPrefix("note-") else { return current }
        // Only the file the app wrote is renamed, and never over another.
        guard let onDisk = NoteFile.identity(at: fileURL(for: current)), onDisk == known.sameInode else { return current }
        do {
            try NoteFile.moveExclusively(fileURL(for: current), to: fileURL(for: wanted))
        } catch {
            return current
        }
        var moved = note
        moved.id = wanted
        let wasLoaded = notes[current]?.bodyIsLoaded == true
        if wasLoaded { unaccount(current) }
        notes[current] = nil
        identities[wanted] = identities.removeValue(forKey: current)
        if let count = retained.removeValue(forKey: current) { retained[wanted] = count }
        moved.bodyIsLoaded = wasLoaded
        notes[wanted] = moved
        if wasLoaded { account(wanted, bytes: moved.text.utf8.count) }
        onEvent(.renamed(from: current, to: wanted))
        return wanted
    }

    /// The write transaction (see the type's note), and the one place bytes
    /// reach the folder: the access is asked here first, so no continuation
    /// (the debounce, a close, quit, a folder switch) writes — or diverts to
    /// a conflict copy — after the license lapsed, unless the buffer is
    /// `accepted` text the user typed while it was allowed, which is always
    /// flushed (and may divert like any other write). Returns `.saved`, or
    /// `.keptAsConflictCopy` when the file had changed outside — before the
    /// check, or between the check and the swap.
    private func write(_ id: NoteID) throws -> SaveOutcome {
        guard let note = notes[id] else { throw StoreError.noSuchNote(id) }
        if note.truncated { throw StoreError.oversized(id) }
        guard note.bodyIsLoaded else { throw StoreError.entryChanged(id) }
        if provisional.contains(id), identities[id] == nil, note.isEmpty { return .notWritten }
        guard !readOnly || accepted.contains(id) else { throw StoreError.readOnly }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            folderIsMissing = true
            onEvent(.folderMissing)
            throw StoreError.folderMissing(folder)
        }
        let url = fileURL(for: id)
        let contents = FrontMatter.serialize(note)
        var attempts = 0
        while true {
            attempts += 1
            switch NoteFile.open(url) {
            case .absent:
                #if DEBUG
                interleavingHook?(.beforeCreate(id))
                #endif
                do {
                    identities[id] = try NoteFile.createExclusively(url, contents: contents)
                    dirty.remove(id)
                    accepted.remove(id)
                    return .saved
                } catch NoteFile.Failure.exists {
                    // Somebody made the file meanwhile: look again, at most a few times.
                    guard attempts < 3 else { return try divert(id, note: note) }
                    continue
                } catch {
                    throw StoreError.io("\(url.lastPathComponent): \(error)")
                }
            case .notRegular:
                throw StoreError.entryChanged(id)
            case .file(let fd, let info):
                defer { NoteFile.close(fd) }
                guard let known = identities[id], (info.st_dev, info.st_ino) == known.sameInode,
                      let onDisk = NoteFile.read(fd: fd, stat: info, cap: 0),
                      onDisk.identity.hash == known.hash, onDisk.identity.size == known.size,
                      onDisk.identity.size <= Self.maximumFileSize else {
                    return try divert(id, note: note)
                }
                #if DEBUG
                interleavingHook?(.beforeReplace(id))
                #endif
                let temporary: (url: URL, identity: NoteFile.Identity)
                do {
                    temporary = try NoteFile.writeTemporary(beside: url, contents: contents)
                } catch {
                    throw StoreError.io("\(url.lastPathComponent): \(error)")
                }
                do {
                    try NoteFile.swap(temporary.url, url)
                } catch {
                    NoteFile.removeTemporary(temporary.url)
                    throw StoreError.io("\(url.lastPathComponent): \(error)")
                }
                return try settle(id, note: note, url: url, temporary: temporary, known: known, fd: fd, info: info)
            }
        }
    }

    /// After the swap: the happy path (the displaced inode is the verified
    /// one, still holding the verified bytes), the outside-edit path (swap
    /// back, ours to a conflict copy), and the indeterminate path — a
    /// rename the system refused after the first swap. There nothing is
    /// ever deleted: both files are re-read and hashed, whichever names
    /// they ended up under, memory is re-derived from disk, and the note
    /// is not written again until a rescan has re-read it (its identity is
    /// dropped, so any later write diverts instead of replacing).
    private func settle(_ id: NoteID, note: Note, url: URL, temporary: (url: URL, identity: NoteFile.Identity), known: NoteFile.Identity, fd: Int32, info: stat) throws -> SaveOutcome {
        if let displaced = NoteFile.identity(at: temporary.url), displaced == known.sameInode,
           let again = NoteFile.read(fd: fd, stat: info, cap: 0), again.identity.hash == known.hash, again.identity.size == known.size {
            NoteFile.removeTemporary(temporary.url)
            identities[id] = temporary.identity
            dirty.remove(id)
            accepted.remove(id)
            return .saved
        }
        // An outside edit landed between the check and the swap: put it
        // back, and ours goes beside it.
        do {
            try NoteFile.swap(temporary.url, url)
        } catch {
            return try settleIndeterminate(id, note: note, url: url, temporary: temporary, known: known, cause: "\(error)")
        }
        return try divert(id, note: note, ours: temporary.url)
    }

    private func settleIndeterminate(_ id: NoteID, note: Note, url: URL, temporary: (url: URL, identity: NoteFile.Identity), known: NoteFile.Identity, cause: String) throws -> SaveOutcome {
        let ours = temporary.identity.hash
        let atName = NoteFile.open(url).identity(cap: 0)
        let atTemporary = NoteFile.open(temporary.url).identity(cap: 0)
        if atName?.hash == known.hash, atTemporary?.hash == ours {
            // The restoring swap did happen after all: the regular path.
            return try divert(id, note: note, ours: temporary.url)
        }
        if atName?.hash == ours, let theirs = atTemporary, theirs.hash != ours {
            // Ours stayed under the name; the outside version is in the
            // temporary. It is given a visible name beside the note.
            let base = NoteFileName.conflictStem(for: id, at: now())
            var candidate = NoteID(base)
            var counter = 2
            while counter < 1000 {
                if notes[candidate] == nil {
                    do {
                        try NoteFile.moveExclusively(temporary.url, to: fileURL(for: candidate))
                        identities[id] = temporary.identity
                        dirty.remove(id)
                        accepted.remove(id)
                        if case .file(let fd, let info) = NoteFile.open(fileURL(for: candidate)) {
                            defer { NoteFile.close(fd) }
                            if let contents = NoteFile.read(fd: fd, stat: info, cap: Self.readCap(for: info)), let text = contents.text {
                                identities[candidate] = contents.identity
                                store(Self.parse(id: candidate, contents: text, fileDate: contents.identity.modified, fallbackCreated: contents.identity.modified, truncated: contents.truncated))
                            }
                        }
                        onEvent(.updated([id, candidate]))
                        onEvent(.storageProblem("\(url.lastPathComponent) could not be restored after an outside edit (\(cause)); the outside version is kept as \(candidate.fileName)."))
                        return .saved
                    } catch NoteFile.Failure.exists {
                        // Taken: the next suffix.
                    } catch {
                        break
                    }
                }
                candidate = NoteID("\(base)-\(counter)")
                counter += 1
            }
            // The outside version stays in the hidden temporary until a
            // rescan can give it a name; ours is on disk under the note's
            // name, and memory matches it. Any later write diverts.
            identities[id] = nil
            dirty.remove(id)
            accepted.remove(id)
            let message = "\(url.lastPathComponent): an outside edit could not be given a name (\(cause)); it is kept as \(temporary.url.lastPathComponent) until the folder is read again."
            onEvent(.storageProblem(message))
            throw StoreError.io(message)
        }
        // Neither arrangement can be told: touch nothing, trust nothing.
        identities[id] = nil
        let message = "\(url.lastPathComponent) could not be settled after a write (\(cause)); both versions are on disk, nothing was removed, and the note is read again before it is written."
        onEvent(.storageProblem(message))
        throw StoreError.io(message)
    }

    /// Ours to a new note beside the original (from the already-written
    /// temporary when there is one); theirs read back.
    private func divert(_ id: NoteID, note: Note, ours temporary: URL? = nil) throws -> SaveOutcome {
        let wasProvisional = provisional.contains(id) && identities[id] == nil
        var copy = note
        let copyID: NoteID
        var identity: NoteFile.Identity?
        if wasProvisional {
            copyID = NoteFileName.id(for: "", created: note.created) { candidate in
                candidate == id || self.notes[candidate] != nil || self.fileManager.fileExists(atPath: self.fileURL(for: candidate).path)
            }
            copy.id = copyID
            do {
                identity = try NoteFile.createExclusively(fileURL(for: copyID), contents: FrontMatter.serialize(copy))
            } catch {
                identity = nil
            }
        } else {
            let placed = try placeConflictCopy(for: id, note: note, temporary: temporary)
            copyID = placed.id
            copy.id = copyID
            identity = placed.identity
        }
        let wasLoaded = notes[id]?.bodyIsLoaded == true
        if wasLoaded { unaccount(id) }
        copy.bodyIsLoaded = true
        notes[copyID] = copy
        account(copyID, bytes: copy.text.utf8.count)
        if let identity {
            identities[copyID] = identity
            accepted.remove(id)
        } else {
            dirty.insert(copyID)
            if accepted.remove(id) != nil { accepted.insert(copyID) }
        }
        if wasProvisional { provisional.insert(copyID) }
        if let count = retained.removeValue(forKey: id) { retained[copyID] = count }
        provisional.remove(id)
        dirty.remove(id)
        identities[id] = nil
        // Theirs, under the original id.
        if case .file(let fd, let info) = NoteFile.open(fileURL(for: id)) {
            defer { NoteFile.close(fd) }
            if let theirs = NoteFile.read(fd: fd, stat: info, cap: Self.readCap(for: info)), let text = theirs.text {
                identities[id] = theirs.identity
                notes[id] = nil
                store(Self.parse(id: id, contents: text, fileDate: theirs.identity.modified, fallbackCreated: theirs.identity.modified, truncated: theirs.truncated))
            } else {
                notes[id] = nil
            }
        } else {
            notes[id] = nil
        }
        onEvent(.renamed(from: id, to: copyID))
        if !wasProvisional { onEvent(.conflict(id, copy: fileURL(for: copyID))) }
        if identity == nil { throw StoreError.io("\(copyID.fileName) could not be written; the text is kept and retried.") }
        return .keptAsConflictCopy(copyID)
    }

    /// `<name> (conflict <time>).md`, then `-2`, `-3`… — created
    /// exclusively with the contents, or the already-written temporary
    /// moved there without replacing anything.
    private func placeConflictCopy(for id: NoteID, note: Note, temporary: URL?) throws -> (id: NoteID, identity: NoteFile.Identity?) {
        let base = NoteFileName.conflictStem(for: id, at: now())
        var candidate = NoteID(base)
        var counter = 2
        while counter < 1000 {
            if notes[candidate] == nil {
                var copy = note
                copy.id = candidate
                do {
                    if let temporary {
                        try NoteFile.moveExclusively(temporary, to: fileURL(for: candidate))
                        return (candidate, NoteFile.open(fileURL(for: candidate)).identity(cap: 0))
                    }
                    return (candidate, try NoteFile.createExclusively(fileURL(for: candidate), contents: FrontMatter.serialize(copy)))
                } catch NoteFile.Failure.exists {
                    // Taken: the next suffix.
                } catch {
                    // The temporary (ours, verified) is not deleted: ours is
                    // kept in memory, dirty, and written when the next save
                    // succeeds; the temporary is recovered by a rescan.
                    onEvent(.storageProblem("\(candidate.fileName) could not be written (\(error)); your text is kept in the app and \(temporary?.lastPathComponent ?? "") on disk."))
                    return (candidate, nil)
                }
            }
            candidate = NoteID("\(base)-\(counter)")
            counter += 1
        }
        throw StoreError.io("No free name for a copy of \(id.fileName).")
    }

    // MARK: - Export

    /// `.md` is the text as saved without the front matter; `.txt` strips
    /// the markers too. Works while read-only.
    public func export(_ id: NoteID, as format: ExportFormat) throws -> (name: String, data: Data) {
        guard let note = body(of: id) else { throw StoreError.noSuchNote(id) }
        return Export.file(for: note, as: format)
    }

    // MARK: - Parsing

    static func parse(id: NoteID, contents: String, fileDate: Date, fallbackCreated: Date, truncated: Bool = false) -> Note {
        let parsed = FrontMatter.parse(contents)
        var note = Note(
            id: id, text: parsed.text, color: parsed.color ?? .coral, face: parsed.face ?? .sans,
            pinned: parsed.pinned ?? false, archived: parsed.archived ?? false, order: Note.clampOrder(parsed.order ?? 0),
            created: parsed.created ?? fallbackCreated, modified: max(parsed.modified ?? fileDate, fileDate)
        )
        note.truncated = truncated
        note.bodyIsLoaded = true
        return note
    }
}

private extension NoteFile.Entry {
    /// The identity of an open entry (closing it), hashing the whole file.
    func identity(cap: Int) -> NoteFile.Identity? {
        guard case .file(let fd, let info) = self else { return nil }
        defer { NoteFile.close(fd) }
        return NoteFile.read(fd: fd, stat: info, cap: cap)?.identity
    }
}
