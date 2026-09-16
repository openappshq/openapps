import AppKit
import Observation
import OpenNotesCore

/// The app's one model: the store and its watcher, the preferences, the
/// save debounce and its retries, archive's undo, auto-archive, read-only.
/// The deck controllers, All Notes and Settings all read it; every window
/// change comes through observation.
@Observable
final class AppModel {
    let store: NoteStore
    let preferences: Preferences
    @ObservationIgnored let watcher: FolderWatcher
    /// Bumped on every store event so views re-read the store.
    private(set) var revision = 0
    /// The last save problem, shown in the open note's footer until the
    /// next successful save.
    private(set) var saveProblem: String?
    /// A note's text went to a conflict copy; the footer says so once.
    private(set) var lastConflict: (id: NoteID, original: NoteID)?
    /// The pending Undo for the deck's toast.
    private(set) var undo = ArchiveUndo()
    /// The trial ended or a license is needed (the parity ticket drives
    /// it): the store refuses creating and editing, the deck says why.
    var readOnly = false {
        didSet {
            store.readOnly = readOnly
            revision += 1
        }
    }
    /// What the open note's footer says while read-only; the licensing
    /// wiring supplies the real line.
    var readOnlyNotice = "Read-only: a license is needed to write notes."
    /// A note's identity moved (its file took its title's name, or the
    /// user's text went to a conflict copy): the deck follows.
    @ObservationIgnored var onRedirect: (NoteID, NoteID) -> Void = { _, _ in }

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saveTimers: [NoteID: Timer] = [:]
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var rescanTimer: Timer?
    @ObservationIgnored private var autoArchiveTimer: Timer?
    @ObservationIgnored private var undoTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Typing waits this long before the file is written.
    static let saveDebounce: TimeInterval = 0.25
    /// A failed write is tried again this often while it keeps failing.
    static let retryInterval: TimeInterval = 5

    init(preferences: Preferences, store: NoteStore? = nil, watcher: FolderWatcher = FolderWatcher(), now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.store = store ?? NoteStore(folder: preferences.folder, now: now)
        self.watcher = watcher
        self.now = now
        self.store.onEvent = { [weak self] in self?.handle($0) }
        watcher.onChange = { [weak self] in self?.scheduleRescan() }
    }

    deinit {
        MainActor.assumeIsolated {
            for timer in saveTimers.values { timer.invalidate() }
            retryTimer?.invalidate()
            rescanTimer?.invalidate()
            autoArchiveTimer?.invalidate()
            undoTimer?.invalidate()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        }
    }

    /// Reads the folder, starts the watcher, the activation rescan, the
    /// flushes on resign, sleep and quit, and auto-archive when it is on.
    func start() {
        store.load(create: preferences.usesDefaultFolder)
        watcher.watch(store.folder)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.rescan() }
        })
        // Pending text reaches the disk before the Mac sleeps or the user
        // moves on; a failure keeps it dirty and the retry timer running.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.flush() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.flush() }
        })
        scheduleAutoArchive(runNow: true)
        observeChanges({ [preferences] in _ = preferences.folder }, onChange: { [weak self] in self?.folderChanged() })
        observeChanges({ [preferences] in _ = preferences.autoArchiveDays }, onChange: { [weak self] in self?.scheduleAutoArchive(runNow: true) })
    }

    // MARK: - Notes

    var active: [Note] { _ = revision; return store.active }
    var archived: [Note] { _ = revision; return store.archived }
    var deckOrder: [NoteID] { active.map(\.id) }

    func note(_ id: NoteID) -> Note? {
        _ = revision
        return store.note(id)
    }

    /// A new note with the default face and color; nil (and a footer
    /// problem) when the store refuses.
    func createNote() -> Note? {
        do {
            let note = try store.create(color: preferences.color, face: preferences.face)
            saveProblem = nil
            return note
        } catch {
            saveProblem = error.localizedDescription
            return nil
        }
    }

    /// The editor's text as typed; written after the debounce.
    func setText(_ text: String, for id: NoteID) {
        do {
            try store.setText(text, for: id)
        } catch {
            saveProblem = error.localizedDescription
            return
        }
        saveTimers[id]?.invalidate()
        saveTimers[id] = Timer.scheduledTimer(withTimeInterval: Self.saveDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.save(id) }
        }
    }

    /// Writes now; the footer shows a failure until the next success, and
    /// the write is retried every few seconds while it fails. Returns the
    /// id the note has now (its conflict copy's when the file had changed
    /// outside), or nil when the write failed.
    @discardableResult
    func save(_ id: NoteID) -> NoteID? {
        saveTimers[id]?.invalidate()
        saveTimers[id] = nil
        do {
            let outcome = try store.save(id)
            saveProblem = nil
            revision += 1
            scheduleRetryIfNeeded()
            if case .keptAsConflictCopy(let copy) = outcome { return copy }
            return id
        } catch {
            saveProblem = "Couldn’t save: \(error.localizedDescription)"
            revision += 1
            scheduleRetryIfNeeded()
            return nil
        }
    }

    /// Every unsaved note, now: what could not be written, with why. Used
    /// before a folder switch, sleep, resign and quit.
    @discardableResult
    func flush() -> [NoteID: String] {
        for timer in saveTimers.values { timer.invalidate() }
        saveTimers = [:]
        let problems = store.saveAll()
        saveProblem = problems.isEmpty ? nil : "Couldn’t save: \(problems.values.sorted().first ?? "")"
        revision += 1
        scheduleRetryIfNeeded()
        return problems
    }

    /// A note closing: saved, an empty new one dropped, a new one given
    /// its file name. Returns the id it has now (nil when dropped).
    func closeNote(_ id: NoteID) -> NoteID? {
        if store.discardIfEmpty(id) { return nil }
        guard let saved = save(id) else { return id }
        do {
            return try store.finishProvisional(saved)
        } catch {
            saveProblem = "Couldn’t save: \(error.localizedDescription)"
            return saved
        }
    }

    func setColor(_ color: NoteColor, for id: NoteID) { attempt { try store.setColor(color, for: id) } }
    func setFace(_ face: NoteFace, for id: NoteID) { attempt { try store.setFace(face, for: id) } }
    func setPinned(_ pinned: Bool, for id: NoteID) { attempt { try store.setPinned(pinned, for: id) } }

    /// Out of the deck, with a 10-second Undo. The id is resolved through
    /// any redirect a save made meanwhile.
    func archive(_ id: NoteID) {
        guard let note = store.note(id) else { return }
        let current = save(id) ?? id
        attempt { try store.archive(current) }
        guard store.note(current)?.archived == true else { return }
        undo.archived(current, title: note.title, at: now())
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: ArchiveUndo.window + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undo.expire(at: self.now())
                self.revision += 1
            }
        }
    }

    /// The toast's Undo: the latest archive comes back.
    func undoArchive() {
        guard let id = undo.undo(at: now()) else { return }
        attempt { try store.unarchive(id) }
    }

    func unarchive(_ id: NoteID) {
        undo.forget(id)
        attempt { try store.unarchive(id) }
    }

    func reorder(_ ids: [NoteID]) { attempt { try store.reorder(ids) } }

    var pendingUndo: ArchiveUndo.Pending? {
        _ = revision
        return undo.current(at: now())
    }

    func export(_ id: NoteID, as format: ExportFormat) throws -> (name: String, data: Data) {
        try store.export(id, as: format)
    }

    func revealInFinder(_ id: NoteID) {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: id)])
    }

    /// The footer's "Saved · now" line, or the problem.
    func statusLine(for id: NoteID) -> String {
        _ = revision
        if readOnly { return readOnlyNotice }
        if let saveProblem { return saveProblem }
        if let lastConflict, lastConflict.id == id { return "“\(lastConflict.original.fileName)” was changed outside; your text continues here, in \(id.fileName)." }
        guard let note = store.note(id) else { return "" }
        if note.truncated { return "Too large to edit here; shown in part." }
        if store.hasUnsavedChanges(id) { return "Editing…" }
        return "Saved · \(Age.text(note.modified, now: now()))"
    }

    func clearConflictNotice() {
        lastConflict = nil
    }

    // MARK: - Folder

    /// The chosen folder changed: pending text is written to the old one
    /// first; if any of it cannot be, the setting goes back to the old
    /// folder and the footer says why (the text stays, dirty, retried).
    private func folderChanged() {
        let old = store.folder
        guard preferences.folder != old else { return }
        do {
            try store.switchFolder(to: preferences.folder, create: preferences.usesDefaultFolder)
            watcher.watch(store.folder)
            saveProblem = nil
        } catch {
            saveProblem = "Couldn’t switch folders: \(error.localizedDescription)"
            preferences.folder = old
            scheduleRetryIfNeeded()
        }
        revision += 1
    }

    private func scheduleRescan() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.rescan() }
        }
    }

    /// While a write keeps failing, try again every few seconds; nothing
    /// runs once everything is saved.
    private func scheduleRetryIfNeeded() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard !store.unsavedNotes.isEmpty, saveProblem != nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.flush() }
        }
    }

    /// Auto-archive runs now (when asked) and then once, at the moment the
    /// next note falls due; nothing is scheduled while it is off or no
    /// note can fall due.
    private func scheduleAutoArchive(runNow: Bool) {
        autoArchiveTimer?.invalidate()
        autoArchiveTimer = nil
        let days = preferences.autoArchiveDays
        guard days > 0 else { return }
        if runNow {
            for id in AutoArchive.candidates(in: store.active, days: days, now: now()) {
                attempt { try store.archive(id) }
            }
        }
        guard let due = AutoArchive.nextDue(in: store.active, days: days) else { return }
        let delay = max(60, due.timeIntervalSince(now()))
        autoArchiveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAutoArchive(runNow: true) }
        }
    }

    private func handle(_ event: StoreEvent) {
        switch event {
        case .renamed(let from, let to):
            onRedirect(from, to)
        case .conflict(let original, let copy):
            lastConflict = (NoteID(copy.deletingPathExtension().lastPathComponent), original)
        default:
            break
        }
        revision += 1
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            saveProblem = nil
        } catch {
            saveProblem = error.localizedDescription
            revision += 1
        }
        scheduleRetryIfNeeded()
    }
}
