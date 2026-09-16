import Foundation
@testable import OpenNotes
import OpenNotesCore
import OpenAppsLicensing
import Testing

/// The whole chain as the app wires it, without the app: the real
/// `LicenseManager` with OpenNotes' values and fakes publishes snapshots to
/// a box (the controller's feed), `LicenseStatus` asks the projection of
/// that snapshot to the fake clocks on every read, and the model asks the
/// status at every action and the store asks it again at the file. The
/// assertions are the outputs — the card, the badge, the note's text, the
/// file's bytes, the folder's listing, mtimes — for each restricted state
/// and across deadlines no timer delivered.
@Suite("Licensing enforcement")
@MainActor
struct EnforcementTests {
    /// OpenNotes' Dodo product in test mode.
    static let paid = "pdt_0NnjxPRw1V6N34ObK6jzN"

    let clock = FakeClock()
    let client = FakeClient()
    let store = MemoryStore()
    let journal = MemoryJournal()
    let trialStore = MemoryTrialStore()
    let registry = FakeRegistry()
    let device = FakeDevice()
    let feed = SnapshotBox()
    let status = LicenseStatus()
    let folder: URL
    let temporary: TemporaryDefaults
    let model: AppModel

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-enforcement-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A temporary notes folder seeded with a few real files, so
        // enforcement is checked at the file, not only in memory.
        for (name, text) in [
            ("shopping", "Shopping\n- [ ] milk\n- [ ] eggs"),
            ("trip", "Trip planning\nBook flights, pack bags."),
            ("ideas", "Ideas\nWrite the thing."),
        ] {
            try! Data(text.utf8).write(to: folder.appendingPathComponent("\(name).md"))
        }
        temporary = try! TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let clock = self.clock
        model = AppModel(preferences: preferences, license: status, store: NoteStore(folder: folder) { clock.now }, watcher: FolderWatcher()) { clock.now }
        model.store.load(create: false)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        temporary.remove()
    }

    /// Everything the launch path wires, on fakes: the manager loaded and
    /// its launch check run, the status the model holds bound to the
    /// projection of the manager's latest published snapshot.
    func attach() async -> LicenseManager {
        let clock = self.clock
        let feed = self.feed
        let manager = LicenseManager(
            appID: Licensing.appID, products: LicenseProducts(paid: [Self.paid]), client: client, store: store, journal: journal,
            trialStore: trialStore, registry: registry, device: device, trialTiming: Licensing.trialTiming,
            now: { clock.now }, uptime: { clock.uptime }
        )
        await manager.setOnChange { feed.snapshot = $0 }
        await manager.load()
        await manager.checkOnLaunch()
        let project: () -> LicenseState = { feed.snapshot.state(now: clock.now, uptime: clock.uptime) }
        status.bind(
            access: { project().isFeatureEnabled },
            state: { project() },
            restriction: { LicenseRestriction.card(for: project(), storageError: feed.snapshot.storageError != nil, trialStorageError: feed.snapshot.trialStorageError != nil) },
            badge: { LicenseBadge.label(for: project(), appName: Licensing.appName, storageError: feed.snapshot.storageError != nil, trialStorageError: feed.snapshot.trialStorageError != nil) },
            canBuy: true
        )
        return manager
    }

    func trialRecord(elapsed: TimeInterval, registered: Bool = true) -> TrialRecord {
        TrialRecord(startedAt: clock.now.addingTimeInterval(-elapsed), lastSeenAt: clock.now, registered: registered)
    }

    func paidRecord(lastSuccessAge age: TimeInterval) -> LicenseRecord {
        LicenseRecord(
            licenseKey: "KEY", instanceID: "inst_1", productID: Self.paid,
            activatedAt: clock.now.addingTimeInterval(-30 * FakeClock.day), lastSuccessAt: clock.now.addingTimeInterval(-age)
        )
    }

    /// What every restricted state must look like at the outputs: the card
    /// and the badge say so, the deck stays visible and every note stays
    /// readable, searchable and exportable, and creating, editing, renaming,
    /// archiving, unarchiving, reordering, the flags and the folder are all
    /// refused — no file is written or removed, nothing in memory changes.
    /// `provisionalNoteID`, when given, is a note created and left with text
    /// while still allowed: closing it here must not rename it (the
    /// read-only path refuses `finishProvisional`, the file change a close
    /// would otherwise make).
    @discardableResult
    func expectRestricted(title: String, provisionalNoteID: NoteID? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool {
        #expect(!status.hasAccess(), sourceLocation: sourceLocation)
        #expect(status.restriction()?.title == title, sourceLocation: sourceLocation)
        #expect(status.badge()?.tone == .attention, sourceLocation: sourceLocation)
        #expect(model.readOnly, sourceLocation: sourceLocation)
        #expect(model.createNote() == nil, sourceLocation: sourceLocation)

        guard let noteID = (model.active.first ?? model.archived.first)?.id else {
            Issue.record("expected a seeded note to check enforcement against", sourceLocation: sourceLocation)
            return false
        }
        let fileURL = model.store.fileURL(for: noteID)
        let bytesBefore = try? Data(contentsOf: fileURL)
        let noteBefore = model.note(noteID)
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        model.setText((noteBefore?.text ?? "") + " — refused edit", for: noteID)
        #expect(model.note(noteID)?.text == noteBefore?.text, sourceLocation: sourceLocation)
        #expect((try? Data(contentsOf: fileURL)) == bytesBefore, "no file write for a refused edit", sourceLocation: sourceLocation)

        model.archive(noteID)
        model.unarchive(noteID)
        model.setPinned(true, for: noteID)
        model.setColor(.mint, for: noteID)
        model.setFace(.mono, for: noteID)
        model.reorder(model.active.map(\.id).reversed())

        #expect(model.note(noteID) == noteBefore, "no flag changes while read-only", sourceLocation: sourceLocation)
        #expect((try? Data(contentsOf: fileURL)) == bytesBefore, sourceLocation: sourceLocation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == listingBefore, "no file created or removed", sourceLocation: sourceLocation)
        #expect(((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date) == mtimeBefore, sourceLocation: sourceLocation)

        if let provisionalNoteID {
            let before = model.note(provisionalNoteID)
            let closed = model.closeNote(provisionalNoteID)
            #expect(closed == provisionalNoteID, "finishProvisional is a file change, refused while read-only: the id does not change", sourceLocation: sourceLocation)
            #expect(model.note(provisionalNoteID) == before, sourceLocation: sourceLocation)
        }

        #expect(model.mayChangeFolder() == false, sourceLocation: sourceLocation)
        let folderBefore = model.preferences.folder
        #expect(model.setFolder(FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)")) == false, sourceLocation: sourceLocation)
        #expect(model.preferences.folder == folderBefore, sourceLocation: sourceLocation)
        #expect(model.useDefaultFolder() == false, sourceLocation: sourceLocation)
        #expect(model.preferences.folder == folderBefore, sourceLocation: sourceLocation)

        let exported = try? model.export(noteID, as: .markdown)
        #expect(exported != nil, "reading, searching and exporting still work while read-only", sourceLocation: sourceLocation)

        #expect(model.statusLine(for: noteID) == model.readOnlyNotice, sourceLocation: sourceLocation)
        #expect(model.readOnlyNotice == status.restriction()?.notice, sourceLocation: sourceLocation)
        #expect(model.saveProblem == nil, "a refusal is never reported as a save problem", sourceLocation: sourceLocation)
        return true
    }

    /// The feature runs: create, edit and save reach the file; archive works.
    @discardableResult
    func expectAllowed(sourceLocation: SourceLocation = #_sourceLocation) throws -> NoteID {
        #expect(status.hasAccess(), sourceLocation: sourceLocation)
        #expect(status.restriction() == nil, sourceLocation: sourceLocation)
        #expect(!model.readOnly, sourceLocation: sourceLocation)
        let note = try #require(model.createNote(), sourceLocation: sourceLocation)
        model.setText("Allowed check \(UUID().uuidString)", for: note.id)
        #expect(model.save(note.id) != nil, sourceLocation: sourceLocation)
        #expect(FileManager.default.fileExists(atPath: model.store.fileURL(for: note.id).path), sourceLocation: sourceLocation)
        model.archive(note.id)
        #expect(model.archived.contains { $0.id == note.id }, sourceLocation: sourceLocation)
        model.unarchive(note.id)
        return note.id
    }

    // MARK: Each restricted state, at the outputs

    @Test("13. Ended trial at launch: the card, no create, no write, no network calls")
    func trialEnded() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day + 60)
        _ = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Your free trial has ended")
        #expect(status.restriction()?.actions == [.buy, .enterKey])
        #expect(status.badge()?.text == "Trial ended")
        #expect(registry.devices.isEmpty && client.calls.isEmpty)
    }

    @Test("17. Unreadable trial record: storage error card, nothing saved, no new trial", arguments: [LicenseStoreError.unavailable("locked"), .corrupt])
    func trialStorageError(error: LicenseStoreError) async throws {
        trialStore.record = trialRecord(elapsed: 3600, registered: false)
        trialStore.readError = error
        let manager = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Can’t read or save the free trial record")
        #expect(status.restriction()?.actions.first == .tryAgain)
        #expect(trialStore.saves.isEmpty && registry.devices.isEmpty)
        // Readable again ("Try again"): writing comes back.
        trialStore.readError = nil
        await manager.tick(wake: true)
        try expectAllowed()
    }

    @Test("Unregistered trial past its offline limit: connect to continue")
    func trialNeedsConnection() async throws {
        trialStore.record = trialRecord(elapsed: 25 * 3600, registered: false)
        registry.result = .unreachable
        _ = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Connect to the internet to continue your free trial")
        #expect(status.restriction()?.actions == [.tryAgain, .buy, .enterKey])
    }

    @Test("14. Clock behind at launch: held off, nothing saved, back with the day that was left")
    func trialClockBehind() async throws {
        trialStore.record = trialRecord(elapsed: 2 * FakeClock.day)
        clock.advance(-5 * FakeClock.day)
        let manager = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Your Mac’s clock is behind")
        #expect(trialStore.saves.isEmpty)
        // The wall clock looks right again: still held until the manager
        // observes it — a projection never releases a held clock.
        clock.now = FakeClock.start.addingTimeInterval(-30 * 60)
        #expect(!status.hasAccess())
        #expect(model.createNote() == nil)
        await manager.tick()
        #expect(status.state() == .trial(daysLeft: 1))
        try expectAllowed()
    }

    @Test("8. Licensed, 8 days without a check and offline: check required, no Buy")
    func checkRequired() async throws {
        store.record = paidRecord(lastSuccessAge: 8 * FakeClock.day)
        client.validation = .unreachable
        _ = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Connect to the internet to verify your license")
        #expect(status.restriction()?.actions == [.tryAgain, .enterKey])
    }

    @Test("10. Licensed, then valid: false: revoked at once")
    func revoked() async throws {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .valid(serverDate: clock.now)
        let manager = await attach()
        defer { tearDown() }
        let provisional = try expectAllowed()
        // A second note created and left open while still allowed: closing
        // it after the revocation must not rename it.
        let openNote = try #require(model.createNote())
        model.setText("Not yet closed", for: openNote.id)
        // Refunded meanwhile: the next daily check answers valid: false.
        client.validation = .invalid
        clock.advance(LicensePolicy.checkInterval + 1)
        await manager.tick()
        try expectRestricted(title: "This license is no longer active on this Mac", provisionalNoteID: openNote.id)
        #expect(status.restriction()?.actions == [.enterKey, .buy])
        _ = provisional
    }

    // MARK: Storage errors, at the app outputs

    @Test("An unreadable license record is a storage error, not \"no license\": the card, no Dodo call, then readable restores", arguments: [LicenseStoreError.unavailable("locked"), .corrupt])
    func licenseRecordStorageError(error: LicenseStoreError) async throws {
        // Otherwise plainly licensed, if only the record could be read.
        store.record = paidRecord(lastSuccessAge: 3600)
        store.readError = error
        let manager = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Can’t read the license record")
        #expect(status.restriction()?.actions.first == .tryAgain)
        #expect(client.calls.isEmpty, "no Dodo call while the record itself cannot even be read")
        // Readable again ("Try again" / a wake): the stored record decides.
        store.readError = nil
        await manager.tick(wake: true)
        try expectAllowed()
    }

    @Test("An activation whose record save is indeterminate keeps writing off until the retry lands")
    func indeterminateActivationSaveKeepsWritingOff() async throws {
        trialStore.record = trialRecord(elapsed: 4 * FakeClock.day) // trial already ended
        client.activation = .activated(Activation(instanceID: "inst_1", productID: Self.paid, productName: "OpenNotes", createdAt: clock.now, serverDate: clock.now))
        store.indeterminateSaves = true
        let manager = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Your free trial has ended")
        #expect(await manager.activate(key: "OPENNOTES-KEY") == .activated, "the activation itself succeeded with Dodo")
        // The record is in place but not confirmed durable: access still
        // comes from what the store last confirmed (nothing), so the trial
        // rules still decide — an ended trial, still restricted.
        #expect(status.state() == .trialEnded, "not licensed yet: the save never confirmed")
        try expectRestricted(title: "Your free trial has ended")
        #expect(await manager.storageError == .indeterminate("not yet confirmed"))
        // The retry succeeds: the record becomes durable at the manager,
        // and access follows it there right away.
        store.indeterminateSaves = false
        await manager.tick()
        #expect(await manager.state == .licensed, "the manager's own state confirms the retry landed")
        #expect(await manager.storageError == nil)
        // `retryStorage()`'s silent confirm (`flushRecord` alone, no
        // `notify()`) does not itself push a fresh snapshot to `onChange` —
        // unlike every other retry path here, which does (`reloadFromStore`,
        // `applySuccess`, `write`). In the real app this is exactly the gap
        // between the manager already being licensed and the next timer,
        // wake or action re-reading it — `feed.snapshot` stands in for that
        // next read, not for anything this test invented.
        feed.snapshot = await manager.snapshot
        #expect(status.state() == .licensed)
        try expectAllowed()
    }

    @Test("A paid record whose journal entry is unreadable holds the feature off (check required) until a successful check settles it")
    func unreadableJournalForAPaidRecordHoldsCheckRequired() async throws {
        store.record = paidRecord(lastSuccessAge: 3600) // otherwise plainly licensed
        journal.readError = .unavailable("locked")
        // Unreachable at launch, so `checkOnLaunch()`'s own check does not
        // settle this before the restricted assertions below ever run.
        client.validation = .unreachable
        let manager = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Connect to the internet to verify your license")
        #expect(await manager.journalUnreadable)
        #expect(await manager.storageError != nil)
        #expect(status.restriction()?.actions.contains(.tryAgain) == true)
        // A successful check settles the unreadable entry and turns writing on.
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(await !manager.journalUnreadable)
        try expectAllowed()
    }

    @Test("Text accepted while allowed still diverts to a conflict copy after the deadline, exactly as it would allowed")
    func acceptedTextDivertsToAConflictCopyAcrossExpiry() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        defer { tearDown() }
        let noteID = try #require(model.active.first?.id)
        model.setText("Our edit", for: noteID) // accepted: typed while allowed
        let fileURL = model.store.fileURL(for: noteID)
        let outsideText = "Someone else's edit, longer"
        try Data(outsideText.utf8).write(to: fileURL)
        model.store.rescan()
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        clock.advance(120) // the trial ends before the flush
        // The buffer was stamped `accepted` the moment it was typed, so its
        // flush goes through the write transaction whatever the license says
        // now — including the transaction's own conflict handling.
        let copyID = try #require(model.save(noteID), "accepted text is always flushed")
        #expect(copyID != noteID)
        #expect(try Data(contentsOf: fileURL) == Data(outsideText.utf8), "the original file keeps the outside version")
        #expect(model.note(noteID)?.text == outsideText, "the original id now holds the outside text, read back")
        #expect(model.note(copyID)?.text == "Our edit", "ours continues in the copy")
        #expect(!model.store.hasUnsavedChanges(copyID))
        #expect(FileManager.default.fileExists(atPath: model.store.fileURL(for: copyID).path))
        let listingAfter = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(listingAfter.count == listingBefore.count + 1)
        #expect(listingAfter.contains { $0.contains("conflict") })
        #expect(model.statusLine(for: copyID) == model.readOnlyNotice, "read-only for everything else, even the note the text landed in")
    }

    @Test("A fully saved note is never touched by a refused save or flush, even with an outside edit waiting")
    func fullySavedNoteWithOutsideEditAfterExpiryIsUntouched() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        defer { tearDown() }
        let noteID = try #require(model.active.first?.id)
        model.setText("Saved before the deadline", for: noteID)
        #expect(model.save(noteID) == noteID, "written while allowed: no divert, no rename")
        #expect(!model.store.hasUnsavedChanges(noteID))
        let fileURL = model.store.fileURL(for: noteID)
        let outsideText = "Someone else's edit, arriving later"
        try Data(outsideText.utf8).write(to: fileURL)
        model.store.rescan() // a plain read: not dirty, so this alone updates memory
        #expect(model.note(noteID)?.text == outsideText)
        #expect(!model.store.hasUnsavedChanges(noteID))
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        clock.advance(120)
        // Nothing dirty: `save` and `flush` find `.unchanged` before the
        // read-only guard is ever asked — not a refusal, just nothing to do.
        #expect(model.save(noteID) == noteID)
        #expect(model.flush().isEmpty)
        #expect(try Data(contentsOf: fileURL) == Data(outsideText.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == listingBefore)
        #expect(!listingBefore.contains { $0.contains("conflict") })
    }

    @Test("Text accepted while allowed is written by flush() too, even after the deadline")
    func acceptedTextIsWrittenByFlushAfterTheDeadline() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        defer { tearDown() }
        let noteID = try #require(model.active.first?.id)
        model.setText("Typed with a minute to spare", for: noteID)
        clock.advance(120)
        let problems = model.flush()
        #expect(problems.isEmpty)
        #expect(!model.store.hasUnsavedChanges(noteID))
        #expect(try String(contentsOf: model.store.fileURL(for: noteID), encoding: .utf8).contains("Typed with a minute to spare"))
        #expect(model.statusLine(for: noteID) == model.readOnlyNotice, "read-only for everything else, even though this text landed")
    }

    // MARK: Deadlines nobody delivered

    @Test("A trial that ends between ticks: the next action refuses, before any deadline callback")
    func trialEndsWithoutACallback() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        defer { tearDown() }
        #expect(status.badge()?.text == "Free trial · less than a day left")
        // A note created and left with text while still allowed.
        let openNote = try #require(model.createNote())
        model.setText("Started before the deadline", for: openNote.id)
        try expectAllowed()
        // Two minutes pass. No manager tick, no timer, no publish: the
        // projection alone decides.
        clock.advance(120)
        try expectRestricted(title: "Your free trial has ended", provisionalNoteID: openNote.id)
    }

    @Test("28. A frozen wall clock does not extend the trial: monotonic time ends it")
    func monotonicTimeEndsTheTrial() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60)
        _ = await attach()
        defer { tearDown() }
        try expectAllowed()
        clock.uptime += 120 // the wall clock stands still
        try expectRestricted(title: "Your free trial has ended")
    }

    @Test("20. An unregistered trial reaches 24 h between ticks: off until the registry answers")
    func offlineLimitWithoutACallback() async throws {
        trialStore.record = trialRecord(elapsed: 24 * 3600 - 60, registered: false)
        registry.result = .unreachable
        let manager = await attach()
        defer { tearDown() }
        try expectAllowed()
        clock.advance(120)
        try expectRestricted(title: "Connect to the internet to continue your free trial")
        // The registry answers with the same start: the trial resumes with what is left.
        registry.result = .registered(startedAt: clock.now.addingTimeInterval(-(24 * 3600 + 60)), now: clock.now)
        await manager.tick(wake: true)
        #expect(status.state() == .trial(daysLeft: 2))
        try expectAllowed()
    }

    @Test("Grace ends between ticks: check required, before any deadline callback")
    func graceEndsWithoutACallback() async throws {
        store.record = paidRecord(lastSuccessAge: LicensePolicy.graceDuration - 60)
        client.validation = .unreachable
        _ = await attach()
        defer { tearDown() }
        #expect(status.badge()?.text.hasPrefix("Connect to the internet within") == true)
        try expectAllowed()
        clock.advance(120)
        try expectRestricted(title: "Connect to the internet to verify your license")
    }

    @Test("1. Activation during an ended trial turns writing on at the next action")
    func activationRestores() async throws {
        trialStore.record = trialRecord(elapsed: 4 * FakeClock.day)
        client.activation = .activated(Activation(instanceID: "inst_1", productID: Self.paid, productName: "OpenNotes", createdAt: clock.now, serverDate: clock.now))
        let manager = await attach()
        defer { tearDown() }
        try expectRestricted(title: "Your free trial has ended")
        #expect(await manager.activate(key: "OPENNOTES-KEY") == .activated)
        #expect(status.restriction() == nil && status.badge() == nil)
        #expect(status.state() == .licensed)
        try expectAllowed()
    }

    // MARK: Auto-archive and the license observer

    @Test("The auto-archive sweep asks the license before it runs: none of it while restricted, all of it once start() runs it allowed")
    func autoArchiveRefusesWhileRestricted() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60) // one minute of trial left
        _ = await attach()
        defer { tearDown() }
        model.preferences.autoArchiveDays = 1
        // An old, unpinned seeded note past the auto-archive window.
        let oldID = try #require(model.active.first?.id)
        try Data(FrontMatter.serialize(Note(id: oldID, text: "Old note", order: -1, created: clock.now.addingTimeInterval(-3 * FakeClock.day), modified: clock.now.addingTimeInterval(-3 * FakeClock.day))).utf8)
            .write(to: model.store.fileURL(for: oldID))
        model.store.rescan()
        #expect(AutoArchive.candidates(in: model.active, days: 1, now: clock.now).contains(oldID))
        clock.advance(120) // the trial ends before start()'s sweep can run
        #expect(!status.hasAccess())
        // `scheduleAutoArchive` (private) is reached only through `start()`,
        // which is safe here: a temporary folder, no window.
        model.start()
        #expect(model.archived.map(\.id).contains(oldID) == false, "refused: the sweep asked the license and it said no")
    }

    @Test("Once writing is allowed again, the auto-archive refused earlier runs; a flag held on an empty provisional note is finally written once it has text")
    func restoringAccessReRunsAutoArchiveAndFlushesAHeldFlagChange() async throws {
        trialStore.record = trialRecord(elapsed: 3 * FakeClock.day - 60) // one minute left
        client.activation = .activated(Activation(instanceID: "inst_1", productID: Self.paid, productName: "OpenNotes", createdAt: clock.now, serverDate: clock.now))
        let manager = await attach()
        defer { tearDown() }
        model.preferences.autoArchiveDays = 1
        let oldID = NoteID("trip")

        // A brand-new, still-empty note: a pin set on it while allowed sits
        // in memory only (an empty provisional note is never written,
        // license or not) — this is the one kind of pending change a
        // deadline can still hold, since typing accepted text no longer can.
        let held = try #require(model.createNote())
        model.setPinned(true, for: held.id)
        #expect(model.store.hasUnsavedChanges(held.id))
        #expect(!FileManager.default.fileExists(atPath: model.store.fileURL(for: held.id).path))

        clock.advance(120) // the trial ends before start()'s sweep, or anything else
        model.start() // wires the license.revision observer, on the temp folder
        // An old, unpinned note that would be an auto-archive candidate once it can run.
        try Data(FrontMatter.serialize(Note(id: oldID, text: model.note(oldID)?.text ?? "Trip planning", order: 5, created: clock.now.addingTimeInterval(-3 * FakeClock.day), modified: clock.now.addingTimeInterval(-3 * FakeClock.day))).utf8)
            .write(to: model.store.fileURL(for: oldID))
        model.store.rescan()
        #expect(AutoArchive.candidates(in: model.active, days: 1, now: clock.now).contains(oldID))

        #expect(model.flush().isEmpty, "the held pin change is not reported as a failure")
        #expect(model.store.hasUnsavedChanges(held.id), "still dirty: an empty provisional note is never written")
        #expect(model.archived.map(\.id).contains(oldID) == false, "auto-archive is still refused")

        #expect(await manager.activate(key: "OPENNOTES-KEY") == .activated)
        status.publish() // the manager's own change does not publish LicenseStatus; the app's launch path does this on `onChange`
        for _ in 0..<50 { await Task.yield() }

        #expect(status.hasAccess())
        #expect(model.archived.map(\.id).contains(oldID), "the auto-archive the observer re-ran picked up the old note")
        #expect(model.store.hasUnsavedChanges(held.id), "the pin alone still has nowhere to go: the note is still empty")

        // The user finally types something: the held pin and the new text
        // reach the disk together.
        model.setText("Finally has something to say", for: held.id)
        #expect(model.save(held.id) != nil)
        #expect(!model.store.hasUnsavedChanges(held.id))
        #expect(FileManager.default.fileExists(atPath: model.store.fileURL(for: held.id).path))
        #expect(model.note(held.id)?.pinned == true, "the flag set long before is still there")
    }
}

#if OPENAPPS_LICENSING
/// The same deadlines through the real `LicenseController`: its `state`
/// is the projection at the moment it is asked, so the model and the
/// status bound to it refuse before its deadline timer runs.
@Suite("License controller enforcement")
@MainActor
struct LicenseControllerEnforcementTests {
    let clock = FakeClock()
    let trialStore = MemoryTrialStore()

    func makeController() -> LicenseController {
        let clock = self.clock
        let manager = LicenseManager(
            appID: Licensing.appID, products: LicenseProducts(paid: [EnforcementTests.paid]), client: FakeClient(), store: MemoryStore(),
            journal: MemoryJournal(), trialStore: trialStore, registry: FakeRegistry(), device: FakeDevice(),
            trialTiming: Licensing.trialTiming, now: { clock.now }, uptime: { clock.uptime }
        )
        return LicenseController(manager: manager, now: { clock.now }, uptime: { clock.uptime })
    }

    /// The controller's snapshot feed hops to the main queue; let it land.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func startsRestrictedUntilStorageAnswers() {
        let controller = makeController()
        #expect(controller.state == .trialUnavailable)
        #expect(!controller.isFeatureEnabled)
        #expect(controller.badge?.text == "Starting your free trial…")
        #expect(controller.restriction?.title == "Starting your free trial…")
        #expect(controller.freshInstall == nil)
        #expect(LicenseController.trialText(daysLeft: 2) == "Free trial: 2 days left")
        #expect(LicenseController.trialText(daysLeft: 1) == "Free trial: less than a day left")
    }

    @Test("The trial ends between ticks: the controller, the status and the model refuse without its timer")
    func trialEndsWithoutTheDeadlineTimer() async throws {
        trialStore.record = TrialRecord(startedAt: clock.now.addingTimeInterval(-(3 * FakeClock.day - 60)), lastSeenAt: clock.now, registered: true)
        let controller = makeController()
        await controller.attach()
        await settle()
        #expect(controller.state == .trial(daysLeft: 1))
        #expect(controller.isFeatureEnabled)

        let status = LicenseStatus()
        status.bind(
            access: { [weak controller] in controller?.isFeatureEnabled ?? false },
            state: { [weak controller] in controller?.state },
            restriction: { [weak controller] in controller?.restriction },
            badge: { [weak controller] in controller?.badge },
            canBuy: true
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-controller-enforcement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: status, store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)

        let note = try #require(model.createNote())
        model.setText("Before the deadline", for: note.id)
        #expect(model.save(note.id) != nil)
        #expect(status.badge()?.text == "Free trial · less than a day left")

        clock.advance(120) // no timer fires, no snapshot arrives
        #expect(controller.state == .trialEnded)
        #expect(!controller.isFeatureEnabled)
        #expect(!status.hasAccess())
        #expect(status.restriction()?.title == "Your free trial has ended")
        #expect(model.createNote() == nil)
        let bytesBefore = try? Data(contentsOf: model.store.fileURL(for: note.id))
        model.setText("Should not land", for: note.id)
        #expect((try? Data(contentsOf: model.store.fileURL(for: note.id))) == bytesBefore)
        #expect(model.statusLine(for: note.id) == model.readOnlyNotice)
    }
}
#endif
