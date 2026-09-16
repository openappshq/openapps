import XCTest
@testable import OpenNotesCore

/// A `FileManager` whose overridden `fileExists(atPath:isDirectory:)` starts
/// a background writer once armed, mirroring the reviewer's timing probe
/// (`/tmp/opennotes-review2-probes/write-race.swift`): the write transaction's
/// only `FileManager` call before it opens the note's own descriptor is the
/// folder-existence guard, so arming there reproduces the exact interleaving
/// the review used, without needing the deterministic `interleavingHook`.
private final class RacingManager: FileManager, @unchecked Sendable {
    var target: URL?
    var done: DispatchSemaphore?
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let result = super.fileExists(atPath: path, isDirectory: isDirectory)
        if let target, let done {
            self.target = nil
            DispatchQueue.global().async {
                usleep(200)
                try? Data("EXTERNAL BETWEEN CHECK AND REPLACE".utf8).write(to: target, options: .atomic)
                done.signal()
            }
        }
        return result
    }
}

/// Regression tests for review 2's four P0s (app-review-2), fixed in
/// d8383f5/3a9e0ed: descriptor-checked transactions (`NoteFile`), a
/// whole-file hash, a body budget, and auto-archive re-arm (P1, in
/// `FixRound2AppTests`). Each test reproduces a review probe against the
/// current store, using `interleavingHook` where the review used a
/// `FileManager` subclass, since the transaction is now built on `NoteFile`
/// primitives that don't go through `FileManager` for the file itself.
final class NoteStoreFixRound2Tests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)
    private var events: [StoreEvent] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix2-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor private func makeStore(create: Bool = true) -> NoteStore {
        let store = NoteStore(folder: folder) { [self] in clock }
        store.onEvent = { [self] in events.append($0) }
        store.load(create: create)
        return store
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - P0-1: the interleaved cleanup race, via the hook

    /// Mirrors the reviewer's `ReplacingRemover` probe, moved to the
    /// deterministic `beforeUnlink` hook: right where round-2's cleanup is
    /// about to `unlinkat` the verified descriptor's name, an outside actor
    /// replaces the path with a directory holding a file of its own.
    /// `unlinkat` without `AT_REMOVEDIR` refuses a directory by construction
    /// (`NoteFile.unlink`), so cleanup reports failure and nothing is
    /// removed; on 302aa02, `discardIfEmpty` still called recursive
    /// `FileManager.removeItem`, which would have deleted the directory and
    /// `precious.txt` with it.
    @MainActor func testDiscardIfEmptyBeforeUnlinkHookDirectorySwapSurvives() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("saved provisional", for: note.id)
        try store.save(note.id)
        try store.setText("", for: note.id)
        let url = store.fileURL(for: note.id)
        store.interleavingHook = { interleaving in
            guard case .beforeUnlink(let id) = interleaving, id == note.id else { return }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try? Data("foreign precious".utf8).write(to: url.appendingPathComponent("precious.txt"))
        }
        let removed = store.discardIfEmpty(note.id)
        store.interleavingHook = nil
        XCTAssertFalse(removed)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("precious.txt"), encoding: .utf8), "foreign precious")
        // The note is gone from memory either way; a rescan skips the
        // directory (not a `.md` regular file) rather than adopting it.
        XCTAssertNil(store.note(note.id))
    }

    /// The plain (no-hook) foreign-replacement case: a different regular
    /// file sitting at the provisional path when Escape runs. The
    /// descriptor check's hash/size comparison rejects it before any
    /// removal is attempted, so it survives and the note in memory picks up
    /// the foreign text once `keepAsForeign`'s rescan runs.
    @MainActor func testDiscardIfEmptyForeignRegularFileWrittenBeforeDiscardSurvives() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("saved provisional", for: note.id)
        try store.save(note.id)
        try store.setText("", for: note.id)
        try write(note.id.fileName, "foreign valuable")
        let removed = store.discardIfEmpty(note.id)
        XCTAssertFalse(removed)
        XCTAssertEqual(try read(note.id.fileName), "foreign valuable")
        XCTAssertEqual(store.note(note.id)?.text, "foreign valuable")
        XCTAssertFalse(store.hasUnsavedChanges(note.id))
    }

    /// The ordinary case, with the hook never armed: cleanup still removes
    /// its own untouched file.
    @MainActor func testDiscardIfEmptyPlainCaseStillDeletesWithoutAHook() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("saved provisional", for: note.id)
        try store.save(note.id)
        try store.setText("", for: note.id)
        XCTAssertTrue(store.discardIfEmpty(note.id))
        XCTAssertEqual(try files(), [])
        XCTAssertNil(store.note(note.id))
    }

    // Note: the same-instant REGULAR-FILE swap at `.beforeUnlink` (a foreign
    // process writing its own `note-YYYYMMDD-HHmm.md` under the exact
    // provisional name in the microsecond between the descriptor check and
    // the unlink-by-name) is the review's documented residual: POSIX has no
    // unlink-by-descriptor, so that file is what gets unlinked. Intentionally
    // not tested here — it is not a regression to catch, it's the accepted
    // remaining gap.

    // MARK: - P0-2: the write transaction under an interleaved outside writer

    /// The existing file is replaced with an entirely new inode (`.atomic`)
    /// right before the swap: the displaced-identity check (different
    /// device/inode) catches it, the swap is undone, and ours goes to a
    /// conflict copy — with no leftover `.tmp-` file.
    @MainActor func testBeforeReplaceHookNewInodeDivertsWithNoLeftoverTempFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "original")
        let store = makeStore()
        try store.setText("ours", for: NoteID("a"))
        store.interleavingHook = { [folder] interleaving in
            guard case .beforeReplace(let id) = interleaving, id == NoteID("a") else { return }
            try? Data("EXTERNAL BETWEEN CHECK AND REPLACE".utf8).write(to: folder!.appendingPathComponent("a.md"), options: .atomic)
        }
        let outcome = try store.save(NoteID("a"))
        store.interleavingHook = nil
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertEqual(try read("a.md"), "EXTERNAL BETWEEN CHECK AND REPLACE")
        XCTAssertEqual(store.note(copy)?.text, "ours")
        let renamed = StoreEvent.renamed(from: NoteID("a"), to: copy)
        let conflict = StoreEvent.conflict(NoteID("a"), copy: store.fileURL(for: copy))
        guard let renamedIndex = events.firstIndex(of: renamed), let conflictIndex = events.firstIndex(of: conflict) else {
            return XCTFail("missing renamed/conflict events: \(events)")
        }
        XCTAssertLessThan(renamedIndex, conflictIndex)
        let names = try files()
        XCTAssertEqual(names.filter { $0.hasSuffix(".md") }.count, 2, "\(names)")
        XCTAssertTrue(names.allSatisfy { !$0.contains(".tmp-") }, "\(names)")
    }

    /// The addendum's strong form (3a9e0ed): the outside edit lands IN
    /// PLACE, same inode — `FileHandle(forWritingTo:)`, truncate, overwrite.
    /// The displaced-identity check alone would pass (same device/inode), so
    /// round-2's re-hash through the descriptor still open on it is what has
    /// to catch this. It must: a.md keeps the in-place text, ours goes to a
    /// conflict copy, no leftover `.tmp-` file.
    @MainActor func testBeforeReplaceHookInPlaceEditDivertsWithNoLeftoverTempFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("a.md", "original")
        let store = makeStore()
        try store.setText("ours", for: NoteID("a"))
        let url = folder.appendingPathComponent("a.md")
        store.interleavingHook = { interleaving in
            guard case .beforeReplace(let id) = interleaving, id == NoteID("a") else { return }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.truncateFile(atOffset: 0)
            handle.write(Data("IN PLACE".utf8))
            try? handle.close()
        }
        let outcome = try store.save(NoteID("a"))
        store.interleavingHook = nil
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertEqual(try read("a.md"), "IN PLACE")
        XCTAssertEqual(store.note(copy)?.text, "ours")
        let names = try files()
        XCTAssertEqual(names.filter { $0.hasSuffix(".md") }.count, 2, "\(names)")
        XCTAssertTrue(names.allSatisfy { !$0.contains(".tmp-") }, "\(names)")
    }

    /// `beforeCreate` on a brand-new provisional note: an outside writer
    /// takes the provisional name the instant before the exclusive create.
    /// Ours moves on to the next free provisional name; the outside file is
    /// never touched.
    @MainActor func testBeforeCreateHookCollisionOnAProvisionalNoteDivertsToANewName() throws {
        let store = makeStore()
        let note = try store.create(color: .coral)
        try store.setText("mine", for: note.id)
        store.interleavingHook = { [store] interleaving in
            guard case .beforeCreate(let id) = interleaving, id == note.id else { return }
            try? Data("taken".utf8).write(to: store.fileURL(for: note.id))
        }
        let outcome = try store.save(note.id)
        store.interleavingHook = nil
        guard case .keptAsConflictCopy(let newID) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertTrue(newID.rawValue.hasPrefix("note-"), newID.rawValue)
        XCTAssertNotEqual(newID, note.id)
        XCTAssertEqual(try read(note.id.fileName), "taken")
        XCTAssertEqual(store.note(note.id)?.text, "taken")
        XCTAssertEqual(store.note(newID)?.text, "mine")
    }

    /// The reviewer's timing probe (write-race.swift), run three times with
    /// a real background writer racing the save: which branch wins (the
    /// pre-swap check, or the post-swap displaced-identity re-check) is not
    /// deterministic, so this only asserts what must always hold — the
    /// outside text survives, at most two `.md` files exist, and no
    /// `.tmp-` file is left behind. Bounded so a hung race fails fast
    /// instead of hanging the suite.
    @MainActor func testConcurrentBackgroundWriterNeverLosesTheOutsideEdit() throws {
        for run in 0..<3 {
            let raceFolder = folder.appendingPathComponent("race-\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: raceFolder, withIntermediateDirectories: true)
            let url = raceFolder.appendingPathComponent("a.md")
            try Data("original".utf8).write(to: url)
            let fm = RacingManager()
            let store = NoteStore(folder: raceFolder, fileManager: fm) { [self] in clock }
            store.load(create: false)
            try store.setText(String(repeating: "ours ", count: 800_000), for: NoteID("a"))
            let done = DispatchSemaphore(value: 0)
            fm.target = url
            fm.done = done
            _ = try store.save(NoteID("a"))
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "background writer never ran (run \(run))")
            let value = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(value, "EXTERNAL BETWEEN CHECK AND REPLACE", "outside edit lost on run \(run)")
            let names = try FileManager.default.contentsOfDirectory(atPath: raceFolder.path)
            XCTAssertLessThanOrEqual(names.filter { $0.hasSuffix(".md") }.count, 2, "run \(run): \(names)")
            XCTAssertTrue(names.allSatisfy { !$0.contains(".tmp-") }, "run \(run): \(names)")
        }
    }

    // MARK: - P0-3: the whole-file hash

    /// The reviewer's exact probe: a 64,000-byte prefix hash used to be
    /// treated as proof the whole (now 1,064,001-byte) file was unchanged.
    /// Round-2's size guard (`onDisk.identity.size <= maximumFileSize`)
    /// rejects any current file over the cap outright, so this diverts
    /// rather than overwriting the outside growth.
    @MainActor func testOversizedPrefixHashNeverAuthorizesOverwritingADirtySave() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = String(repeating: "a", count: 64_000)
        try write("a.md", prefix)
        let store = makeStore()
        try store.setText("our changed text", for: NoteID("a"))
        let outside = prefix + String(repeating: "Z", count: 1_000_001)
        try write("a.md", outside)
        let outcome = try store.save(NoteID("a"))
        guard case .keptAsConflictCopy(let copy) = outcome else { return XCTFail("expected keptAsConflictCopy, got \(outcome)") }
        XCTAssertEqual(try read("a.md"), outside)
        let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("a.md").path)[.size] as? Int
        XCTAssertEqual(size, 1_064_001)
        XCTAssertEqual(store.note(copy)?.text, "our changed text")
    }

    /// The clean-rescan variant: no unsaved edit, the file just grows past
    /// the cap outside while keeping the same prefix. The full-file hash
    /// (computed over every byte read, not just the kept preview) no longer
    /// matches the old one, so the note is re-read as truncated rather than
    /// left stale.
    @MainActor func testCleanRescanMarksOversizedGrowthAsTruncated() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = String(repeating: "a", count: 64_000)
        try write("a.md", prefix)
        let store = makeStore()
        XCTAssertEqual(store.note(NoteID("a"))?.truncated, false)
        let outside = prefix + String(repeating: "Z", count: 1_000_001)
        try write("a.md", outside)
        store.rescan()
        let note = try XCTUnwrap(store.note(NoteID("a")))
        XCTAssertTrue(note.truncated)
        XCTAssertLessThanOrEqual(note.text.utf8.count, NoteStore.truncatedPreviewSize)
    }
}

/// P0-4: the aggregate body budget (`NoteStore.bodyBudget`), lazy reload,
/// and the pieces (`search`, `export`, `NoteStore.summary`) that read
/// through it.
final class NoteStoreFixRound2BudgetTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix2-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The reviewer's 12 × 900,000-byte fixture ("title\n" + a's, no front
    /// matter). A budget of 3,000,000 only fits three notes' bodies at once.
    private func writeFixture(uniqueWordInLast: String? = nil) throws {
        let bodyFiller = String(repeating: "a", count: 900_000 - 6)
        for i in 0..<12 {
            var body = "title\n" + bodyFiller
            if let uniqueWordInLast, i == 11 {
                body = "title\n" + String(bodyFiller.dropLast(uniqueWordInLast.count)) + uniqueWordInLast
            }
            try Data(body.utf8).write(to: folder.appendingPathComponent("\(i).md"))
        }
    }

    @MainActor private func makeStore(bodyBudget: Int = NoteStore.defaultBodyBudget) -> NoteStore {
        let store = NoteStore(folder: folder, bodyBudget: bodyBudget) { [self] in clock }
        store.load(create: false)
        return store
    }

    /// After load, every note is present with a title either way; the
    /// budget holds; bodies past it fall back to a bounded summary.
    @MainActor func testBodyBudgetLoadsWithinBudgetAndEvictsToSummaries() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        XCTAssertEqual(store.notes.count, 12)
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, 3_000_000)
        var sawEvicted = false
        for note in store.notes.values {
            XCTAssertFalse(note.title.isEmpty, note.id.rawValue)
            if !note.bodyIsLoaded {
                sawEvicted = true
                XCTAssertLessThanOrEqual(note.text.utf8.count, NoteStore.summarySize, note.id.rawValue)
            }
        }
        XCTAssertTrue(sawEvicted, "12 × 900,000 bytes over a 3,000,000 budget should evict at least one")
    }

    /// `body(of:)` on an evicted note reads the full text back from disk.
    @MainActor func testBodyOfReloadsAnEvictedNoteFully() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        let evictedID = try XCTUnwrap(store.notes.values.first { !$0.bodyIsLoaded }?.id)
        let reloaded = try XCTUnwrap(store.body(of: evictedID))
        XCTAssertTrue(reloaded.bodyIsLoaded)
        XCTAssertEqual(reloaded.text.utf8.count, 900_000)
    }

    /// `body(of:)` reloading an evicted note has to charge the bytes it
    /// brings back in to `retainedBodyBytes` and make room first (c3b4c9c) —
    /// the doc comment on `body(of:)` says the note is "moved to the front
    /// of the budget's line". With a 3 MB budget and 900,000-byte bodies,
    /// exactly 3 fit at once, so reloading one evicts another and the total
    /// stays put at 2,700,000: the number to pin is not "more bytes
    /// retained" but that `retainedBodyBytes` always equals what is
    /// actually held (`bodyIsLoaded` notes' text) — that equality is
    /// exactly what silently drifted before the fix, since the reloaded
    /// body was held but never charged. Reload every evicted note in turn
    /// and check the invariant holds after each one, plus that at most 3
    /// bodies are ever loaded at once.
    @MainActor func testReloadingEvictedBodiesKeepsAccountingEqualToWhatIsHeld() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        func loadedBytes() -> Int {
            store.notes.values.filter(\.bodyIsLoaded).reduce(0) { $0 + $1.text.utf8.count }
        }
        let evictedIDs = store.notes.values.filter { !$0.bodyIsLoaded }.map(\.id)
        XCTAssertFalse(evictedIDs.isEmpty, "fixture should have at least one evicted note to reload")
        for id in evictedIDs {
            let reloaded = try XCTUnwrap(store.body(of: id))
            XCTAssertTrue(reloaded.bodyIsLoaded, id.rawValue)
            XCTAssertEqual(store.note(id)?.bodyIsLoaded, true, id.rawValue)
            XCTAssertLessThanOrEqual(store.retainedBodyBytes, 3_000_000, id.rawValue)
            XCTAssertEqual(store.retainedBodyBytes, loadedBytes(), "retainedBodyBytes must equal what bodyIsLoaded notes actually hold — \(id.rawValue)")
            XCTAssertLessThanOrEqual(store.notes.values.filter(\.bodyIsLoaded).count, 3, id.rawValue)
        }
    }

    /// A dirty note's body is never evicted, even while other bodies are
    /// being loaded on demand.
    @MainActor func testDirtyNoteIsNeverEvictedWhileLoadingFurtherBodies() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        let dirtyID = try XCTUnwrap(store.notes.keys.sorted().first)
        // An edit starts from a loaded body (the app retains a note before
        // it opens); an evicted body is never edited from its summary.
        _ = store.body(of: dirtyID)
        try store.setText(String(repeating: "b", count: 900_000), for: dirtyID)
        XCTAssertTrue(store.hasUnsavedChanges(dirtyID))
        for id in store.notes.keys where id != dirtyID {
            _ = store.body(of: id)
        }
        XCTAssertEqual(store.note(dirtyID)?.bodyIsLoaded, true)
        XCTAssertEqual(store.note(dirtyID)?.text.utf8.count, 900_000)
    }

    /// `retain` keeps a note loaded across other bodies being read in;
    /// `release` lets the budget consider it again.
    @MainActor func testRetainKeepsANoteLoadedAcrossOtherBodyReads() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        let retainID = try XCTUnwrap(store.notes.keys.sorted().first)
        store.retain(retainID)
        XCTAssertEqual(store.note(retainID)?.bodyIsLoaded, true)
        for id in store.notes.keys where id != retainID {
            _ = store.body(of: id)
        }
        XCTAssertEqual(store.note(retainID)?.bodyIsLoaded, true, "a retained note must not be evicted")
        store.release(retainID)
    }

    /// `search` finds every note (evicted or not) without retaining what it
    /// reads: `retainedBodyBytes` is unchanged after the search.
    @MainActor func testSearchFindsAllNotesWithoutRetainingEvictedBodies() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        let before = store.retainedBodyBytes
        let found = store.search("title", archived: false)
        XCTAssertEqual(found.count, 12)
        XCTAssertEqual(store.retainedBodyBytes, before)
    }

    /// A word only present at the very end of one note's 900,000-byte body
    /// (well past `summarySize`) still has to be found: `search` reads the
    /// evicted body's file directly rather than matching only the retained
    /// summary text.
    @MainActor func testSearchFindsOnlyTheNoteWithAUniqueWordBeyondTheSummary() throws {
        try writeFixture(uniqueWordInLast: "ZEBRAWORD")
        let store = makeStore(bodyBudget: 3_000_000)
        let found = store.search("ZEBRAWORD", archived: false)
        XCTAssertEqual(found.map(\.id.rawValue), ["11"])
    }

    /// Export reads the full text of an evicted note, not its summary.
    @MainActor func testExportOfAnEvictedNoteReturnsTheFullText() throws {
        try writeFixture()
        let store = makeStore(bodyBudget: 3_000_000)
        let evictedID = try XCTUnwrap(store.notes.values.first { !$0.bodyIsLoaded }?.id)
        let (_, data) = try store.export(evictedID, as: .markdown)
        XCTAssertEqual(data.count, 900_000)
    }

    /// The reviewer's probe with the default budget: 12 × 900 KB stays
    /// within the 8,000,000-byte default (the review found 7.2 MB of 10.8
    /// retained). All 12 notes are the same size, so — regardless of
    /// directory enumeration order — exactly 8 of them (7,200,000 bytes)
    /// fit and 4 are summarised.
    @MainActor func testDefaultBudgetRetainsWithinEightMillionBytes() throws {
        try writeFixture()
        let store = makeStore()
        XCTAssertEqual(store.bodyBudget, NoteStore.defaultBodyBudget)
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, NoteStore.defaultBodyBudget)
        XCTAssertEqual(store.retainedBodyBytes, 7_200_000)
    }

    /// `NoteStore.summary` cuts at a character boundary: a multi-byte
    /// character straddling the 1,024-byte cut must not corrupt the result.
    @MainActor func testSummaryCutsAtACharacterBoundary() {
        let text = "x" + String(repeating: "é", count: 1_000)
        let summary = NoteStore.summary(of: text)
        XCTAssertLessThanOrEqual(summary.utf8.count, NoteStore.summarySize)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertNotNil(String(data: Data(summary.utf8), encoding: .utf8))
    }
}
