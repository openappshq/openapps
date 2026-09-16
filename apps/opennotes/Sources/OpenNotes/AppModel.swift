import AppKit
import Observation
import OpenNotesCore

/// The app's one model: the store and its watcher, the preferences, the
/// save debounce and its retries, archive's undo, auto-archive, read-only.
/// The deck controllers, All Notes and Settings all read it; every window
/// change comes through observation.
///
/// Read-only (LICENSING.md): `license` is the projected entitlement, asked
/// afresh at every mutation here (`allowed()`), again by the store at the
/// file (`NoteStore.access`), and never stored. A keystroke, a close, a
/// folder panel left open, auto-archive — each asks at its own moment, so
/// a deadline that passed between two renders refuses the very next
/// action. The one thing a deadline never takes is text already typed
/// while it was allowed: the store stamps that buffer and its flush (the
/// debounce, a close, sleep, quit) is written whatever the license says
/// then; the restriction applies to new edits only.
@Observable
final class AppModel {
    let store: NoteStore
    let preferences: Preferences
    /// What the views and the store read about licensing; bound by the
    /// launch path in an official build, always on from source.
    let license: LicenseStatus
    /// What All Notes' footer and the status menu read about an update;
    /// bound by an official build, never from source.
    let updates = UpdateStatus()
    @ObservationIgnored let watcher: FolderWatcher
    /// Bumped on every store event so views re-read the store.
    private(set) var revision = 0
    /// The last save problem, shown in the open note's footer until the
    /// next successful save.
    private(set) var saveProblem: String?
    /// A note's text went to a conflict copy; the footer says so once.
    private(set) var lastConflict: (id: NoteID, original: NoteID)?
    /// What the last storage switch copied (Settings shows it under the
    /// choice until the next switch).
    private(set) var storageNotice: String?
    /// The store's last `storageProblem` (a write it could not settle
    /// cleanly; every version on disk under some name), shown in the
    /// note's footer, All Notes and Settings until the next write of any
    /// note goes through without one.
    private(set) var storageProblem: String?
    /// The pending Undo for the deck's toast.
    private(set) var undo = ArchiveUndo()
    /// The trial ended or a license is needed: the store refuses every
    /// change, the deck and All Notes say why. Never stored: the license's
    /// projection at the moment it is read (observers re-read when the
    /// status publishes).
    var readOnly: Bool { !license.hasAccess() }
    /// What the open note's footer and the status menu say while read-only.
    var readOnlyNotice: String {
        license.restriction()?.notice ?? "Read-only: a license is needed to write notes. Your notes stay readable; Settings → License."
    }
    /// A note's identity moved (its file took its title's name, or the
    /// user's text went to a conflict copy): the deck follows.
    @ObservationIgnored var onRedirect: (NoteID, NoteID) -> Void = { _, _ in }

    /// Each note's checklist as last parsed (nil: the note has no box),
    /// dropped when its text changes here or on disk, so the deck's tabs
    /// read a count on every render without a parse (`checklistProgress`).
    @ObservationIgnored private var checklists: [NoteID: MarkdownLite.ChecklistProgress?] = [:]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saveTimers: [NoteID: Timer] = [:]
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var rescanTimer: Timer?
    /// The rescan every `ubiquityRescanInterval` while the folder is
    /// iCloud's, and the one that confirms a file found missing is gone.
    @ObservationIgnored private var ubiquityTimer: Timer?
    @ObservationIgnored private var removalTimer: Timer?
    @ObservationIgnored private var autoArchiveTimer: Timer?
    @ObservationIgnored private var undoTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Typing waits this long before the file is written.
    static let saveDebounce: TimeInterval = 0.25
    /// A failed write is tried again this often while it keeps failing.
    static let retryInterval: TimeInterval = 5
    /// While the folder is iCloud's the folder is read again this often
    /// besides the watcher: iCloud brings files in by rename, and a
    /// placeholder turning into a file is not always an event.
    static let ubiquityRescanInterval: TimeInterval = 30

    init(preferences: Preferences, license: LicenseStatus = LicenseStatus(), store: NoteStore? = nil, watcher: FolderWatcher = FolderWatcher(), now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.license = license
        self.store = store ?? NoteStore(folder: preferences.folder, now: now)
        self.watcher = watcher
        self.now = now
        // The store asks the same projection at every write, so no
        // continuation reaches the file after the license lapsed.
        self.store.access = { [license] in license.hasAccess() }
        self.store.onEvent = { [weak self] in self?.handle($0) }
        watcher.onChange = { [weak self] in self?.scheduleRescan() }
    }

    /// The license, asked at the action. Refused, nothing changes; the
    /// footer and All Notes already say why (`readOnlyNotice`, the card).
    func allowed() -> Bool {
        license.hasAccess()
    }

    deinit {
        MainActor.assumeIsolated {
            for timer in saveTimers.values { timer.invalidate() }
            retryTimer?.invalidate()
            rescanTimer?.invalidate()
            ubiquityTimer?.invalidate()
            removalTimer?.invalidate()
            autoArchiveTimer?.invalidate()
            undoTimer?.invalidate()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        }
    }

    /// Reads the folder, starts the watcher, the activation rescan, the
    /// flushes on resign, sleep and quit, and auto-archive when it is on.
    func start() {
        store.load(create: preferences.createsFolder)
        plantWelcomeNoteIfNeeded()
        watcher.watch(store.folder)
        scheduleUbiquityRescan()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
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
        // The license published a change: once writing is allowed again,
        // any change held in memory while read-only reaches the disk and
        // the auto-archive that was refused runs.
        observeChanges({ [license] in _ = license.revision }, onChange: { [weak self] in self?.licenseChanged() })
    }

    private func licenseChanged() {
        guard allowed() else { return }
        _ = flush()
        scheduleAutoArchive(runNow: true)
        // Conflict versions found while read-only are written out now.
        rescan()
    }

    /// The welcome note (`WelcomeNote`), once: the launch that first reads
    /// the folder writes it when the install is fresh — no earlier
    /// preferences, so the trial is starting and writing is allowed — and
    /// the folder holds no note. Decided on that launch whichever way it
    /// went; an upgrade, a folder switched later or a folder emptied by
    /// hand gets no welcome. The license is not asked: an official build's
    /// storage has not answered yet at this point, and a fresh install is
    /// in its trial by definition (LICENSING.md, "States").
    private func plantWelcomeNoteIfNeeded() {
        guard !preferences.hadEarlierPreferences else { return }
        guard WelcomeNote.shouldCreate(flags: preferences.flags, folderIsMissing: store.folderIsMissing, hasNotes: !store.notes.isEmpty) else { return }
        do {
            try store.plant(WelcomeNote.note(created: now()))
        } catch {
            // Nothing the user did: not a save problem to show. The deck
            // simply starts empty, as before.
            revision += 1
        }
    }

    // MARK: - Notes

    var active: [Note] { _ = revision; return store.active }
    var archived: [Note] { _ = revision; return store.archived }
    var deckOrder: [NoteID] { active.map(\.id) }
    /// The pinned ones among them: the group a deck move stays in.
    var pinnedIDs: Set<NoteID> { Set(active.filter(\.pinned).map(\.id)) }

    func note(_ id: NoteID) -> Note? {
        _ = revision
        return store.note(id)
    }

    /// The note with its whole body (read back if the budget had evicted it).
    func body(of id: NoteID) -> Note? {
        _ = revision
        return store.body(of: id)
    }

    /// The deck holds a note open: its body stays whatever the budget.
    func retain(_ id: NoteID) { store.retain(id) }
    func release(_ id: NoteID) { store.release(id) }

    /// The note's checklist for its tab (design/products/opennotes.md,
    /// "Checklist progress"): parsed once per change of the text, from the
    /// body in memory; nil for a note with no box, and nil rather than a
    /// wrong count for one whose whole body is not here (evicted, or cut
    /// at the read cap).
    func checklistProgress(for id: NoteID) -> MarkdownLite.ChecklistProgress? {
        _ = revision
        guard let note = store.note(id), note.bodyIsLoaded, !note.truncated else { return nil }
        if let cached = checklists[id] { return cached }
        let progress = MarkdownLite.checklistProgress(in: note.text)
        checklists[id] = .some(progress)
        return progress
    }

    /// Search over titles and text; evicted bodies are read one at a time.
    func search(_ query: String, archived: Bool) -> [Note] {
        _ = revision
        return store.search(query, archived: archived)
    }

    /// A new note in the colour Settings → Notes gives new notes (random
    /// The paper the next new note takes: Settings' fixed colour, or the
    /// random pick away from the last note created and the deck
    /// neighbours (the refusal card shows it for the note that was not
    /// written).
    var colorForNewNote: NoteColor {
        preferences.colorForNewNote(active: store.active, lastCreated: store.notes.values.max { $0.created < $1.created }, seed: store.notes.count)
    }

    /// away from its neighbours, or the fixed one) and no font of its own
    /// (it follows the default); nil (and a footer problem) when the
    /// store refuses. Asked at the hotkey and at `+`.
    func createNote() -> Note? {
        guard allowed() else { return nil }
        do {
            let note = try store.create(color: colorForNewNote)
            saveProblem = nil
            return note
        } catch {
            saveProblem = error.localizedDescription
            return nil
        }
    }

    /// The editor's text as typed; written after the debounce. Asked at
    /// the keystroke; the debounced save asks again at the file.
    func setText(_ text: String, for id: NoteID) {
        guard allowed() else { return }
        do {
            try store.setText(text, for: id)
        } catch {
            if !Self.isRefusal(error) { saveProblem = error.localizedDescription }
            return
        }
        checklists[id] = nil
        saveTimers[id]?.invalidate()
        saveTimers[id] = Timer.scheduledTimer(withTimeInterval: Self.saveDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.save(id) }
        }
    }

    /// Writes now; the footer shows a failure until the next success, and
    /// the write is retried every few seconds while it fails. Returns the
    /// id the note has now (its conflict copy's when the file had changed
    /// outside), or nil when the write failed. Text typed while allowed is
    /// written even after the deadline; a save the license refuses (a
    /// pending change that is not such text) is not a failure to report or
    /// retry: it stays in memory and is written once allowed.
    @discardableResult
    func save(_ id: NoteID) -> NoteID? {
        saveTimers[id]?.invalidate()
        saveTimers[id] = nil
        do {
            storageProblem = nil
            let outcome = try store.save(id)
            saveProblem = nil
            revision += 1
            scheduleRetryIfNeeded()
            if case .keptAsConflictCopy(let copy) = outcome { return copy }
            return id
        } catch {
            if !Self.isRefusal(error) { saveProblem = "Couldn’t save: \(error.localizedDescription)" }
            revision += 1
            scheduleRetryIfNeeded()
            return nil
        }
    }

    /// Every unsaved note, now: what could not be written, with why. Used
    /// before a folder switch, sleep, resign and quit. While read-only the
    /// store writes the text typed under access and silently skips the
    /// rest, so the quit is never held by the license.
    @discardableResult
    func flush() -> [NoteID: String] {
        for timer in saveTimers.values { timer.invalidate() }
        saveTimers = [:]
        if !store.unsavedNotes.isEmpty { storageProblem = nil }
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
            if !Self.isRefusal(error) { saveProblem = "Couldn’t save: \(error.localizedDescription)" }
            return saved
        }
    }

    func setColor(_ color: NoteColor, for id: NoteID) { attempt { try store.setColor(color, for: id) } }
    /// The note's own font, or nil for the default in Settings.
    func setTypeface(_ typeface: NoteTypeface?, for id: NoteID) { attempt { try store.setTypeface(typeface, for: id) } }
    func setFace(_ face: NoteFace, for id: NoteID) { setTypeface(.face(face), for: id) }
    /// The note's own size, or nil for the default.
    func setFontSize(_ size: Int?, for id: NoteID) { attempt { try store.setFontSize(size, for: id) } }
    /// How a note looks now: its paper and ink, its font after the default
    /// and the not-installed fallback. The deck, All Notes and the harness
    /// all read this one answer.
    func appearance(of note: Note) -> NoteAppearance { NoteAppearance.resolve(note, preferences: preferences) }
    func setPinned(_ pinned: Bool, for id: NoteID) { attempt { try store.setPinned(pinned, for: id) } }

    // MARK: - Folder

    /// Whether the notes folder may be changed now: asked at "Choose…" and
    /// "Use Default", before any panel opens.
    func mayChangeFolder() -> Bool {
        allowed()
    }

    /// Where the notes live, as Settings and the guide show it.
    var storage: StorageChoice {
        _ = revision
        return preferences.storage
    }

    /// The radio in Settings and the guide: On this Mac / iCloud Drive
    /// (only while iCloud Drive is reachable) / Other folder… (the
    /// chooser, `setFolder`). Asked at the click; the folder change that
    /// follows copies the notes over (`folderChanged`).
    @discardableResult
    func setStorage(_ choice: StorageChoice) -> Bool {
        guard allowed() else { return false }
        if choice == .iCloudDrive, !Preferences.iCloudIsAvailable { return false }
        preferences.setStorage(choice)
        return true
    }

    /// The footer's line about iCloud while the folder is iCloud's
    /// (iCloud Drive, or Desktop & Documents kept there): nil otherwise.
    var storageStatusLine: String? {
        _ = revision
        guard store.folderIsUbiquitous else { return nil }
        let place = preferences.storage == .iCloudDrive ? "In iCloud Drive" : "In iCloud"
        if let storageProblem { return "\(place) · \(storageProblem)" }
        if let problem = store.conflictProblem { return "\(place) · \(problem)" }
        if let problem = store.downloadProblem { return "\(place) · \(problem)" }
        return "\(place) · \(store.storageStatus.text)"
    }

    /// A problem the folder has that is not one note's: the store's last
    /// unsettled write, a conflict version it could not keep. Settings
    /// shows it whatever the folder.
    var folderProblem: String? {
        _ = revision
        return storageProblem ?? store.conflictProblem
    }

    /// The folder the open panel returned: asked again here, since the
    /// panel may have stayed open across a deadline. Refused, the
    /// preference and the store are left as they are.
    @discardableResult
    func setFolder(_ url: URL) -> Bool {
        guard allowed() else { return false }
        preferences.folder = url
        return true
    }

    /// Back to `~/Documents/OpenNotes`; the same rule ("On this Mac").
    @discardableResult
    func useDefaultFolder() -> Bool {
        setStorage(.thisMac)
    }

    /// Out of the deck, with a 10-second Undo. The id is resolved through
    /// any redirect a save made meanwhile. Refused while read-only: the
    /// archived flag is written to the file.
    func archive(_ id: NoteID) {
        guard allowed(), let note = store.note(id) else { return }
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

    /// The toast's Undo: the latest archive comes back. Asked at the
    /// click: a toast can outlive the trial by ten seconds.
    func undoArchive() {
        guard allowed(), let id = undo.undo(at: now()) else { return }
        attempt { try store.unarchive(id) }
    }

    func unarchive(_ id: NoteID) {
        guard allowed() else { return }
        undo.forget(id)
        attempt { try store.unarchive(id) }
    }

    /// All Notes' drag: asked when the drop lands.
    func reorder(_ ids: [NoteID]) {
        guard allowed() else { return }
        attempt { try store.reorder(ids) }
    }

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
        if let storageProblem { return storageProblem }
        if let lastConflict, lastConflict.id == id { return "“\(lastConflict.original.fileName)” was changed outside; your text continues here, in \(id.fileName)." }
        guard let note = store.note(id) else { return "" }
        if let refused = store.downloadProblems[id] { return "iCloud Drive refused the download (\(refused)); asked again on the next look." }
        if note.isDownloading, !note.bodyIsLoaded { return "Downloading from iCloud Drive…" }
        if note.isDownloading { return "Waiting for iCloud Drive to bring the file back; your text is kept." }
        if !note.bodyIsLoaded { return "Can’t read this note right now; shown in part." }
        if note.truncated { return "Too large to edit here; shown in part." }
        if store.hasUnsavedChanges(id) { return "Editing…" }
        var line = "Saved · \(Age.text(note.modified, now: now()))"
        if store.folderIsUbiquitous {
            line += store.storageStatus == .allOnThisMac ? " · in iCloud Drive" : " · iCloud Drive: \(store.storageStatus.text)"
        }
        return line
    }

    func clearConflictNotice() {
        lastConflict = nil
    }

    // MARK: - Folder

    /// The chosen folder changed: pending text is written to the old one
    /// first; if any of it cannot be, the setting goes back to the old
    /// folder and the footer says why (the text stays, dirty, retried).
    /// The notes are copied to the new folder, never moved (the report
    /// is the notice under the choice), and the watcher follows.
    private func folderChanged() {
        let old = store.folder
        guard preferences.folder != old else { return }
        do {
            let report = try store.switchFolder(to: preferences.folder, create: preferences.createsFolder, copyingNotes: true)
            storageNotice = report.summary
            watcher.watch(store.folder)
            scheduleUbiquityRescan()
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
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    /// The store reads the folder again; a file it did not find is
    /// confirmed gone by one more read after the grace, so a delete shows
    /// within a second and a rename in progress never drops a note.
    func rescan() {
        store.rescan()
        removalTimer?.invalidate()
        removalTimer = nil
        guard !store.pendingRemovals.isEmpty else { return }
        removalTimer = Timer.scheduledTimer(withTimeInterval: NoteStore.removalGrace + 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    /// The periodic read while the folder is iCloud's; nothing otherwise.
    private func scheduleUbiquityRescan() {
        ubiquityTimer?.invalidate()
        ubiquityTimer = nil
        guard store.folderIsUbiquitous else { return }
        ubiquityTimer = Timer.scheduledTimer(withTimeInterval: Self.ubiquityRescanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
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
    /// note can fall due. The sweep asks the license and, refused, does
    /// nothing and schedules nothing (`licenseChanged` runs it again once
    /// writing is allowed): nothing the user did, so nothing to report.
    private func scheduleAutoArchive(runNow: Bool) {
        autoArchiveTimer?.invalidate()
        autoArchiveTimer = nil
        let days = preferences.autoArchiveDays
        guard days > 0, allowed() else { return }
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
            checklists[from] = nil
            checklists[to] = nil
            onRedirect(from, to)
        case .conflict(let original, let copy):
            checklists[original] = nil
            lastConflict = (NoteID(copy.deletingPathExtension().lastPathComponent), original)
        case .reloaded, .updated:
            // The text may have changed under a cached count.
            if case .updated(let ids) = event { for id in ids { checklists[id] = nil } } else { checklists = [:] }
            // A note that could fall due may have appeared or changed: the
            // next wake follows it (nothing runs now, nothing while off).
            if preferences.autoArchiveDays > 0 { scheduleAutoArchive(runNow: false) }
        case .storageProblem(let message):
            // A write the store could not settle cleanly: nothing was
            // deleted, every version is on disk, and the footer says where.
            storageProblem = message
        case .removed(let ids):
            for id in ids { checklists[id] = nil }
        default:
            break
        }
        revision += 1
    }

    /// A change: asked at the action; a refusal is not a save problem
    /// (the read-only line covers it), any other failure is.
    private func attempt(_ work: () throws -> Void) {
        guard allowed() else { return }
        do {
            storageProblem = nil
            try work()
            saveProblem = nil
        } catch {
            if !Self.isRefusal(error) { saveProblem = error.localizedDescription }
            revision += 1
        }
        scheduleRetryIfNeeded()
    }

    /// The store refused because the license does not allow writing.
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? StoreError) == .readOnly
    }
}
