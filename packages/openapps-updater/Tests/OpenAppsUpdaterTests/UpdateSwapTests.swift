import Foundation
@testable import OpenAppsUpdater
import Testing

/// A temporary Applications folder holding fake bundles told apart by a marker file.
struct AppFolder {
    let url: URL
    let fileManager = FileManager.default

    init() throws {
        url = fileManager.temporaryDirectory.appendingPathComponent("openapps-updater-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func bundle(_ name: String = "App.app", marker: String, in parent: URL? = nil) throws -> URL {
        let bundle = (parent ?? url).appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: bundle.appendingPathComponent("Contents/MacOS/App"))
        return bundle
    }

    /// A staged bundle the way the updater stages one: state `staging`, folder 0700, bundle inside.
    func staged(_ marker: String, for app: URL) throws -> URL {
        let staging = try UpdateSwap.prepareStagingDirectory(for: app)
        return try bundle(app.lastPathComponent, marker: marker, in: staging)
    }

    func marker(_ bundle: URL) -> String {
        (try? String(contentsOf: bundle.appendingPathComponent("Contents/MacOS/App"), encoding: .utf8)) ?? ""
    }

    func names() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func remove() {
        try? fileManager.removeItem(at: url)
    }
}

struct Injected: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@Suite struct UpdateSwapTests {
    @Test func theStagingDirectoryIsPrivateAndRecordedFirst() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staging = try UpdateSwap.prepareStagingDirectory(for: app)
        let mode = try FileManager.default.attributesOfItem(atPath: staging.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(staging.lastPathComponent == ".App.app.update")
        #expect(UpdateSwap.state(for: app) == .staging)
        // Preparing again starts from empty.
        try Data().write(to: staging.appendingPathComponent("leftover"))
        _ = try UpdateSwap.prepareStagingDirectory(for: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func aSwapExchangesTheAppsAndLeavesNothingElse() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        var steps: [UpdateSwap.Step] = []
        var stateAtExchange: UpdateSwap.State?
        try UpdateSwap.swap(app: app, staged: staged) { step in
            steps.append(step)
            if step == .exchange { stateAtExchange = UpdateSwap.state(for: app) }
        }
        #expect(steps == [.mark, .exchange, .markSuperseded])
        // The transaction was recorded before the only mutation.
        #expect(stateAtExchange == .exchanging)
        #expect(folder.marker(app) == "new")
        #expect(folder.names() == ["App.app"])
        #expect(UpdateSwap.state(for: app) == nil)
    }

    @Test func aFailedStateRecordChangesNothing() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        #expect(throws: UpdateSwap.Failure.cannotRecordState("no space")) {
            try UpdateSwap.swap(app: app, staged: staged) { step in
                if step == .mark { throw Injected("no space") }
            }
        }
        #expect(folder.marker(app) == "old")
        #expect(folder.marker(staged) == "new")
        #expect(UpdateSwap.state(for: app) == .staging)
        #expect(folder.names() == [".App.app.update", ".App.app.update.state", "App.app"])
    }

    @Test func aFailedExchangeChangesNothing() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        #expect(throws: UpdateSwap.Failure.exchange("busy")) {
            try UpdateSwap.swap(app: app, staged: staged) { step in
                if step == .exchange { throw Injected("busy") }
            }
        }
        #expect(folder.marker(app) == "old")
        #expect(folder.marker(staged) == "new")
        // Back to a discardable download.
        #expect(UpdateSwap.state(for: app) == .staging)
        #expect(UpdateSwap.recover(app: app) == .cleaned)
        #expect(folder.names() == ["App.app"])
    }

    @Test func aVolumeWithoutAtomicExchangeIsRefused() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        // A staged bundle on another volume: renamex_np answers EXDEV.
        let elsewhere = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("openapps-updater-\(UUID().uuidString)", isDirectory: true)
        let volume = try FileManager.default.attributesOfItem(atPath: elsewhere.deletingLastPathComponent().path)[.systemNumber] as? Int
        let here = try FileManager.default.attributesOfItem(atPath: folder.url.path)[.systemNumber] as? Int
        guard volume != here else { return } // same volume on this Mac; nothing to prove
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let staged = try folder.bundle("App.app", marker: "new", in: elsewhere)
        #expect(throws: UpdateSwap.Failure.atomicExchangeUnsupported) {
            try UpdateSwap.swap(app: app, staged: staged)
        }
        #expect(folder.marker(app) == "old")
        #expect(UpdateSwap.Failure.atomicExchangeUnsupported.errorDescription?.contains("Applications folder") == true)
    }

    @Test func aFailedSupersededRecordPreservesTheOldBundle() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        // The exchange happened; recording its completion did not (a crash there looks the same).
        try UpdateSwap.swap(app: app, staged: staged) { step in
            if step == .markSuperseded { throw Injected("power loss") }
        }
        #expect(folder.marker(app) == "new")
        #expect(UpdateSwap.state(for: app) == .exchanging)
        // The old bundle now sits in staging, of uncertain provenance: preserved, reported, never deleted.
        #expect(UpdateSwap.preservedBackup(for: app) == staged)
        #expect(folder.marker(staged) == "old")
        #expect(UpdateSwap.recover(app: app) == .backupPreserved(staged))
        #expect(folder.marker(staged) == "old")
        // Nothing is staged or swapped over it.
        #expect(throws: UpdateSwap.Failure.backupPreserved(staged)) {
            try UpdateSwap.prepareStagingDirectory(for: app)
        }
        #expect(throws: UpdateSwap.Failure.backupPreserved(staged)) {
            try UpdateSwap.swap(app: app, staged: staged)
        }
        #expect(folder.marker(staged) == "old")
        #expect(folder.marker(app) == "new")
        // Only a deliberate discard removes it, and the state only once the folder is gone.
        try UpdateSwap.discardPreservedBackup(for: app)
        #expect(UpdateSwap.preservedBackup(for: app) == nil)
        #expect(folder.names() == ["App.app"])
        // Afterwards the next update can be staged again.
        _ = try folder.staged("newer", for: app)
        #expect(UpdateSwap.state(for: app) == .staging)
    }

    @Test func aBundleWithoutARecordedStateIsPreserved() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "new")
        // Something left a bundle in the staging folder with no state: unknown provenance.
        let staging = UpdateSwap.stagingDirectory(for: app)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let unknown = try folder.bundle("App.app", marker: "unknown", in: staging)
        #expect(UpdateSwap.recover(app: app) == .backupPreserved(unknown))
        #expect(folder.marker(unknown) == "unknown")
        // An unreadable state is the same.
        try Data("garbage".utf8).write(to: UpdateSwap.stateLocation(for: app))
        #expect(UpdateSwap.recover(app: app) == .backupPreserved(unknown))
        #expect(folder.marker(unknown) == "unknown")
    }

    @Test func recoveryCleansOnlyWhatTheStateSaysIsSafe() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")

        // A download that was never installed (the app was killed while staged).
        var staged = try folder.staged("new", for: app)
        #expect(UpdateSwap.state(for: app) == .staging)
        #expect(UpdateSwap.recover(app: app) == .cleaned)
        #expect(folder.names() == ["App.app"])
        #expect(folder.marker(app) == "old")

        // Killed after the exchange and its record, before the cleanup.
        staged = try folder.staged("new", for: app)
        try UpdateSwap.swap(app: app, staged: staged) { step in
            if step == .markSuperseded {
                // Model the kill after the record by re-recording it and skipping cleanup.
                try UpdateSwap.record(.superseded, for: app)
                throw Injected("killed")
            }
        }
        // `swap` returned without cleanup; the folder holds the old bundle and the state says so.
        #expect(UpdateSwap.state(for: app) == .superseded)
        #expect(folder.marker(app) == "new")
        #expect(folder.marker(staged) == "old")
        #expect(UpdateSwap.recover(app: app) == .cleaned)
        #expect(folder.names() == ["App.app"])
        #expect(folder.marker(app) == "new")

        // Nothing to recover: nothing changes.
        #expect(UpdateSwap.recover(app: app) == .nothing)
        #expect(folder.marker(app) == "new")
    }

    @Test func symbolicLinksAreNeverSwapped() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let real = try folder.bundle("Real.app", marker: "old")
        let app = folder.url.appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: real)
        let staged = try folder.staged("new", for: app)
        #expect(throws: UpdateSwap.Failure.self) {
            try UpdateSwap.swap(app: app, staged: staged)
        }
        #expect(folder.marker(real) == "old")
    }
}

@Suite struct InstallTransactionTests {
    @Test func anAbortBeforeTheCommitPointWins() {
        let transaction = InstallTransaction()
        #expect(transaction.abortUnlessCommitted())
        #expect(!transaction.commit())
    }

    @Test func aCommitBeforeTheAbortWins() {
        let transaction = InstallTransaction()
        #expect(transaction.commit())
        #expect(!transaction.abortUnlessCommitted())
    }

    @Test func theWaiterSeesTheResultOrTimesOut() {
        let transaction = InstallTransaction()
        #expect(transaction.wait(timeout: 0.05) == nil)
        transaction.finish(.failure(Injected("x")))
        guard case .failure(let error)? = transaction.wait(timeout: 1) else {
            Issue.record("expected the failure")
            return
        }
        #expect((error as? Injected)?.message == "x")
    }
}
