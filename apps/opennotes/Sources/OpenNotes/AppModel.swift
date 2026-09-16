import AppKit
import Observation
import OpenNotesCore

/// The app's one model: the store and its watcher, the preferences, the
/// save debounce, archive's undo, auto-archive, read-only. The deck
/// controllers, All Notes and Settings all read it; every window change
/// comes through `onNotesChanged` or observation.
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
    /// A conflict copy was just written for this note; the footer says so once.
    private(set) var lastConflict: (id: NoteID, copy: URL)?
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

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saveTimers: [NoteID: Timer] = [:]
    @ObservationIgnored private var rescanTimer: Timer?
    @ObservationIgnored private var autoArchiveTimer: Timer?
    @ObservationIgnored private var undoTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Typing waits this long before the file is written.
    static let saveDebounce: TimeInterval = 0.25

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
            rescanTimer?.invalidate()
            autoArchiveTimer?.invalidate()
            undoTimer?.invalidate()
            if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        }
    }

    /// Reads the folder, starts the watcher, the activation rescan and the
    /// hourly auto-archive.
    func start() {
        store.load(create: preferences.usesDefaultFolder)
        watcher.watch(store.folder)
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.rescan() }
        }
        runAutoArchive()
        autoArchiveTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAutoArchive() }
        }
        observeChanges({ [preferences] in _ = preferences.folder }, onChange: { [weak self] in self?.folderChanged() })
        observeChanges({ [preferences] in _ = preferences.autoArchiveDays }, onChange: { [weak self] in self?.runAutoArchive() })
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

    /// Writes now; the footer shows a failure until the next success.
    @discardableResult
    func save(_ id: NoteID) -> Bool {
        saveTimers[id]?.invalidate()
        saveTimers[id] = nil
        do {
            _ = try store.save(id)
            saveProblem = nil
            revision += 1
            return true
        } catch {
            saveProblem = "Couldn’t save: \(error.localizedDescription)"
            return false
        }
    }

    /// A note closing: saved, an empty new one dropped, a new one given
    /// its file name. Returns the id it has now (nil when dropped).
    func closeNote(_ id: NoteID) -> NoteID? {
        if store.discardIfEmpty(id) { return nil }
        guard save(id) else { return id }
        return (try? store.finishProvisional(id)) ?? id
    }

    func setColor(_ color: NoteColor, for id: NoteID) { attempt { try store.setColor(color, for: id) } }
    func setFace(_ face: NoteFace, for id: NoteID) { attempt { try store.setFace(face, for: id) } }
    func setPinned(_ pinned: Bool, for id: NoteID) { attempt { try store.setPinned(pinned, for: id) } }

    /// Out of the deck, with a 10-second Undo.
    func archive(_ id: NoteID) {
        guard let note = store.note(id) else { return }
        _ = save(id)
        attempt { try store.archive(id) }
        guard store.note(id)?.archived == true else { return }
        undo.archived(id, title: note.title, at: now())
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
        if let lastConflict, lastConflict.id == id { return "Saved over an outside edit; theirs is kept as “\(lastConflict.copy.lastPathComponent)”." }
        if store.hasUnsavedChanges(id) { return "Editing…" }
        guard let note = store.note(id) else { return "" }
        return "Saved · \(Age.text(note.modified, now: now()))"
    }

    func clearConflictNotice() {
        lastConflict = nil
    }

    // MARK: - Folder

    private func folderChanged() {
        for id in saveTimers.keys { save(id) }
        store.switchFolder(to: preferences.folder, create: preferences.usesDefaultFolder)
        watcher.watch(store.folder)
    }

    private func scheduleRescan() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.rescan() }
        }
    }

    private func runAutoArchive() {
        for id in AutoArchive.candidates(in: store.active, days: preferences.autoArchiveDays, now: now()) {
            attempt { try store.archive(id) }
        }
    }

    private func handle(_ event: StoreEvent) {
        if case .conflict(let id, let copy) = event { lastConflict = (id, copy) }
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
    }
}
