import Foundation
import XCTest
@testable import OpenNotesCore

/// Regression tests for review 3's two P0s and the P1 (app-review-3),
/// fixed in 8ecca95: an indeterminate rename after the first swap never
/// deletes either version (P0-1), the deck holds a note's body once per
/// open and releases it once per close (P0-2), and the store's test seams
/// compile debug-only with a release-binary check for their names (P1).
///
/// P0-1's two data-loss scenarios (a restore-failure recovery, and the
/// identity drop when even the conflict-name move fails) both need a
/// `renamex_np` call to fail mid-transaction. That can't be interposed
/// from inside this XCTest host process — `DYLD_INSERT_LIBRARIES` only
/// takes effect for a process launched with it set, and the test host is
/// already running — so this file covers P0-1 two ways: a subprocess test
/// that runs the reviewer's exact interposed probe end to end (skips if
/// the prebuilt scratch binaries are not present), and deterministic
/// in-repo tests of `rescan`'s recovery of a stranded temporary, which is
/// the same recovery path the failed-restore scenario falls back to.
///
/// Not covered here (documented, not silently dropped):
/// - `placeConflictCopy` never deleting the temporary on a failed move —
///   only reachable by failing `renamex_np(RENAME_EXCL)` inside the write
///   transaction after the swap already succeeded; no deterministic seam
///   exists for that specific point, and the subprocess test's
///   `FAIL_CONFLICT` run exercises the sibling failure (the move out of
///   `settleIndeterminate`) instead.
/// - The identity-drop-then-diverts-next-write guarantee (the final
///   `identities[id] = nil` branch in `settleIndeterminate`) — only
///   reachable when both the restoring swap and the conflict-name move
///   fail in the same transaction; not reachable without two chained
///   syscall faults, so it is covered only by the subprocess test.

// MARK: - P0-1: settle after an indeterminate rename

final class NoteStoreFixRound3StrandedTemporaryTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix3-stranded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// `rescan` (via `load`) recovers a hidden `.<name>.md.tmp-<uuid>` a
    /// cut-short write left behind — the same recovery a failed restore
    /// falls into when even the conflict-name move is refused — as
    /// `<name> (recovered <time>).md`, and removes the hidden file. The
    /// ordinary note beside it is untouched, and a second rescan recovers
    /// nothing further.
    @MainActor func testRescanRecoversAStrandedTemporaryAsANewNote() throws {
        try write("a.md", "A")
        try write(".a.md.tmp-DEADBEEF", "OUTSIDE UNIQUE TEXT")
        let store = NoteStore(folder: folder) { [self] in clock }
        store.load(create: false)

        let recoveredStem = NoteFileName.recoveredStem(for: "a", at: clock)
        let recoveredID = NoteID(recoveredStem)
        XCTAssertEqual(store.note(NoteID("a"))?.text, "A")
        XCTAssertEqual(store.note(recoveredID)?.text, "OUTSIDE UNIQUE TEXT")
        XCTAssertEqual(store.notes.count, 2)
        let names = try files()
        XCTAssertFalse(names.contains(".a.md.tmp-DEADBEEF"), "\(names)")
        XCTAssertTrue(names.contains(recoveredStem + ".md"), "\(names)")

        let before = store.notes.count
        store.rescan()
        XCTAssertEqual(store.notes.count, before, "a second rescan must not recover anything twice")
    }

    /// A name collision at the exact recovered stem (the fixed clock hits
    /// the same instant as an existing note): the stranded temporary gets
    /// the `-2` suffix, `moveExclusively`'s `RENAME_EXCL` never overwriting
    /// the file already there.
    @MainActor func testRescanRecoverySuffixesWhenTheRecoveredNameIsAlreadyTaken() throws {
        try write("a.md", "A")
        try write(".a.md.tmp-DEADBEEF", "OUTSIDE UNIQUE TEXT")
        let recoveredStem = NoteFileName.recoveredStem(for: "a", at: clock)
        try write(recoveredStem + ".md", "precious")
        let store = NoteStore(folder: folder) { [self] in clock }
        store.load(create: false)

        XCTAssertEqual(store.note(NoteID(recoveredStem))?.text, "precious")
        XCTAssertEqual(store.note(NoteID(recoveredStem + "-2"))?.text, "OUTSIDE UNIQUE TEXT")
        let names = try files()
        XCTAssertFalse(names.contains(".a.md.tmp-DEADBEEF"), "\(names)")
    }
}

final class NoteStoreFixRound3RestoreSubprocessTests: XCTestCase {
    /// Prebuilt against 8ecca95's core objects for this review round; not
    /// repo files (scratch artefacts outside the worktree).
    private static let probeDirectory = "/private/tmp/claude-501/-Users-traycer--traycer-worktrees-openappshq--openapps-opennotes-app/6a97cad9-9ad7-44e6-b59a-e674b5dd118c/scratchpad/probes3"

    private func run(_ executable: String, extraEnvironment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The scratch probe prints `root <path>` last; best-effort cleanup of
    /// what it created under its own hardcoded `/tmp/opennotes-review3-probes/`
    /// root (not under `FileManager.default.temporaryDirectory` — that root
    /// is baked into the prebuilt binary, not something this test controls).
    private func cleanUp(_ output: String) {
        for line in output.split(separator: "\n") where line.hasPrefix("root ") {
            try? FileManager.default.removeItem(atPath: String(line.dropFirst("root ".count)))
        }
    }

    /// ENVIRONMENT-DEPENDENT: mirrors the reviewer's exact probe
    /// (`restore.swift` + `fail-restore.c`, an renamex_np `DYLD_INSERT_LIBRARIES`
    /// interposer) as a subprocess against prebuilt binaries linked to this
    /// core's compiled objects at 8ecca95. Skips (does not fail the suite)
    /// if those scratch binaries are not present — they are not checked
    /// into the repo, and CI or a clean checkout will not have them.
    ///
    /// Plain run: the interposer fails only the second `RENAME_SWAP` (the
    /// restoring swap-back in `settle`) — `settleIndeterminate` finds ours
    /// under the note's name and theirs in the temporary, and gives theirs
    /// a `(conflict …).md` name. `FAIL_CONFLICT=1` run: the interposer also
    /// fails every `RENAME_EXCL` (the conflict-name move) — theirs is left
    /// in the hidden temporary and the save throws. Both must keep the
    /// outside text somewhere on disk; neither deletes it.
    func testReviewerRenamexNpProbeSubprocessBothFaultModesKeepTheOutsideText() throws {
        let restore = Self.probeDirectory + "/restore"
        let dylib = Self.probeDirectory + "/fail-restore.dylib"
        guard FileManager.default.fileExists(atPath: restore), FileManager.default.fileExists(atPath: dylib) else {
            throw XCTSkip("reviewer probe binaries not present at \(Self.probeDirectory) — scratch artefacts, not repo files")
        }

        let plain = try run(restore, extraEnvironment: ["DYLD_INSERT_LIBRARIES": dylib])
        defer { cleanUp(plain) }
        XCTAssertTrue(plain.contains("outside survived true"), plain)
        let plainLines = plain.split(separator: "\n").map(String.init)
        XCTAssertTrue(
            plainLines.contains { $0.contains("(conflict ") && $0.contains(".md ") && $0.hasSuffix("OUTSIDE UNIQUE TEXT") },
            "expected a '… (conflict …).md OUTSIDE UNIQUE TEXT' line: \(plain)"
        )

        let failConflict = try run(restore, extraEnvironment: ["DYLD_INSERT_LIBRARIES": dylib, "FAIL_CONFLICT": "1"])
        defer { cleanUp(failConflict) }
        XCTAssertTrue(failConflict.contains("outside survived true"), failConflict)
        let failLines = failConflict.split(separator: "\n").map(String.init)
        XCTAssertTrue(
            failLines.contains { $0.contains(".md.tmp-") && $0.hasSuffix("OUTSIDE UNIQUE TEXT") },
            "expected a '.a.md.tmp-… OUTSIDE UNIQUE TEXT' line: \(failConflict)"
        )
        XCTAssertTrue(failLines.contains { $0.hasPrefix("save error") }, "expected a 'save error' line: \(failConflict)")
    }
}

// MARK: - P0-2: one retain per open, one release per close

final class DeckStateMachineFixRound3Tests: XCTestCase {
    private let a = NoteID("a"), b = NoteID("b")

    /// Reopening the note already open must not emit a second `.openNote`
    /// (which the controller used to answer with an unbalanced `retain`)
    /// — only `.focusNote`, and `editing` still becomes true. Opening a
    /// different note still closes the first and opens the second.
    @MainActor func testReopeningTheAlreadyOpenNoteOnlyFocusesIt() {
        var sut = DeckStateMachine(settings: DeckSettings(), notes: [a, b])
        XCTAssertEqual(sut.handle(.openRequested(a)), [.openNote(a, focus: true)])
        XCTAssertEqual(sut.state, .open(a, editing: true))

        XCTAssertEqual(sut.handle(.openRequested(a)), [.focusNote(a)])
        XCTAssertEqual(sut.state, .open(a, editing: true))

        XCTAssertEqual(sut.handle(.openRequested(b)), [.closeNote(a), .openNote(b, focus: true)])
        XCTAssertEqual(sut.state, .open(b, editing: true))
    }
}

final class NoteStoreFixRound3RetentionTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-fix3-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Mirrors the reviewer's `retention.swift` probe: 12 × 900,000-byte
    /// notes, the default 8,000,000-byte budget, and a `DeckStateMachine`
    /// driven through a controller-shaped effect handler — `.openNote`
    /// retains, `.closeNote` saves and releases, `.focusNote` does nothing
    /// — exactly `DeckPanelController.perform`'s pairing. Before the fix,
    /// reopening the same note (`.openRequested` twice) doubled the retain
    /// without a matching release, and the review's probe found all 12
    /// notes' 10,800,000 bytes retained forever. With the fix, the same
    /// sequence must stay within budget.
    @MainActor func testReopenReleaseCycleAcrossTwelveNotesStaysWithinTheDefaultBudget() throws {
        for i in 0..<12 {
            try Data(String(repeating: "a", count: 900_000).utf8).write(to: folder.appendingPathComponent("n\(i).md"))
        }
        let store = NoteStore(folder: folder) { [self] in clock }
        store.load(create: false)
        var machine = DeckStateMachine(settings: DeckSettings(), notes: store.active.map(\.id))

        func apply(_ effects: [DeckEffect]) {
            for effect in effects {
                switch effect {
                case .openNote(let id, _): store.retain(id)
                case .closeNote(let id):
                    _ = try! store.save(id)
                    store.release(id)
                default: break
                }
            }
        }

        for id in store.notes.keys.sorted() {
            apply(machine.handle(.openRequested(id)))
            apply(machine.handle(.openRequested(id)))
            apply(machine.handle(.escape))
        }

        XCTAssertLessThanOrEqual(store.retainedBodyBytes, NoteStore.defaultBodyBudget)
        XCTAssertLessThanOrEqual(store.notes.values.filter(\.bodyIsLoaded).count, 8, "7,200,000 / 900,000 = 8")
        XCTAssertTrue(store.unsavedNotes.isEmpty)
        XCTAssertFalse(machine.isOpen)

        store.rescan()
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, NoteStore.defaultBodyBudget)
    }

    /// `retain` is a count, not a flag: a second retain needs a matching
    /// second release before the budget can evict the note again.
    @MainActor func testRetainCountRequiresMatchingReleasesBeforeEvictionIsPossible() throws {
        try Data(String(repeating: "a", count: 900_000).utf8).write(to: folder.appendingPathComponent("n1.md"))
        try Data(String(repeating: "b", count: 900_000).utf8).write(to: folder.appendingPathComponent("n2.md"))
        let store = NoteStore(folder: folder, bodyBudget: 1_000_000) { [self] in clock }
        store.load(create: false)
        let n1 = NoteID("n1"), n2 = NoteID("n2")

        store.retain(n1)
        store.retain(n1)
        store.release(n1)
        _ = store.body(of: n2)
        XCTAssertEqual(store.note(n1)?.bodyIsLoaded, true, "one retain still outstanding: must not be evicted")

        store.release(n1)
        store.release(n1)
        _ = store.body(of: n2)
        XCTAssertEqual(store.note(n1)?.bodyIsLoaded, false, "fully released: the 1,000,000-byte budget can evict it again")
        XCTAssertEqual(store.note(n2)?.bodyIsLoaded, true)
    }
}

// MARK: - P1: the debug-only seam and its release-binary check

final class NoteStoreFixRound3DebugSeamTests: XCTestCase {
    /// The store's fault-injection seam (`NoteStore.interleavingHook`,
    /// `StoreInterleaving`) must still compile and be assignable in a
    /// debug/test build (`#if DEBUG` in NoteStore.swift) — every
    /// interleaving test in this file and in FixRound2Tests depends on it.
    /// `verify-release.sh` (checked below) is what keeps it out of a
    /// release binary; this just pins that the seam itself still exists
    /// for tests.
    @MainActor func testInterleavingHookSeamCompilesAndIsAssignableInDebugBuilds() {
        let store = NoteStore(folder: FileManager.default.temporaryDirectory)
        store.interleavingHook = { _ in }
        store.interleavingHook = nil
        XCTAssertNil(store.interleavingHook)
    }
}

final class ScriptsFixRound3ReleaseGateTests: XCTestCase {
    /// A text check on the script itself, not a build: if any of the four
    /// needles this round's fix added to `verify-release.sh`
    /// (`interleavingHook`, `StoreInterleaving`, `beforeReplace`,
    /// `beforeUnlink`) is ever removed, the release gate silently stops
    /// catching a debug seam leaking into a release binary. The actual
    /// strings-in-binary check needs a built release bundle and is run
    /// separately (`UNIVERSAL=1 scripts/bundle.sh` → `scripts/verify-release.sh`),
    /// not exercised here.
    func testVerifyReleaseScriptStillChecksForEveryDebugSeamNeedle() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../scripts/verify-release.sh")
            .standardizedFileURL
        let contents = try String(contentsOf: scriptURL, encoding: .utf8)
        for needle in ["interleavingHook", "StoreInterleaving", "beforeReplace", "beforeUnlink"] {
            XCTAssertTrue(contents.contains(needle), "verify-release.sh no longer checks for '\(needle)'")
        }
    }
}
