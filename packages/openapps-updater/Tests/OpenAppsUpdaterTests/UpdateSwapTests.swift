import Foundation
import OpenAppsUpdater
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
    @Test func theStagingDirectoryIsPrivate() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staging = try UpdateSwap.prepareStagingDirectory(for: app)
        let mode = try FileManager.default.attributesOfItem(atPath: staging.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(staging.lastPathComponent == ".App.app.update")
        // Preparing again starts from empty.
        try Data().write(to: staging.appendingPathComponent("leftover"))
        _ = try UpdateSwap.prepareStagingDirectory(for: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func anAtomicSwapReplacesTheAppAndLeavesNothingElse() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        var steps: [UpdateSwap.Step] = []
        try UpdateSwap.swap(app: app, staged: staged, atomic: true) { steps.append($0) }
        #expect(steps == [.exchange])
        #expect(folder.marker(app) == "new")
        #expect(folder.names() == ["App.app"])
    }

    @Test func aFailedExchangeChangesNothing() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        #expect(throws: UpdateSwap.Failure.exchange("no space")) {
            try UpdateSwap.swap(app: app, staged: staged, atomic: true) { _ in throw Injected("no space") }
        }
        #expect(folder.marker(app) == "old")
        #expect(folder.marker(staged) == "new")
        #expect(folder.names() == [".App.app.update", "App.app"])
    }

    @Test func theFallbackSwapReplacesTheApp() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        var steps: [UpdateSwap.Step] = []
        try UpdateSwap.swap(app: app, staged: staged, atomic: false) { steps.append($0) }
        #expect(steps == [.moveAside, .moveIn])
        #expect(folder.marker(app) == "new")
        #expect(folder.names() == ["App.app"])
    }

    @Test func aFailedSecondMovePutsTheOldAppBack() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        #expect(throws: UpdateSwap.Failure.moveIn("disk full")) {
            try UpdateSwap.swap(app: app, staged: staged, atomic: false) { step in
                if step == .moveIn { throw Injected("disk full") }
            }
        }
        #expect(folder.marker(app) == "old")
        #expect(!FileManager.default.fileExists(atPath: UpdateSwap.previousLocation(for: app).path))
        #expect(!FileManager.default.fileExists(atPath: UpdateSwap.markerLocation(for: app).path))
        // The staged bundle is untouched, so the next attempt can use it.
        #expect(folder.marker(staged) == "new")
    }

    @Test func aFailedFirstMoveChangesNothing() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        #expect(throws: UpdateSwap.Failure.moveAside("busy")) {
            try UpdateSwap.swap(app: app, staged: staged, atomic: false) { step in
                if step == .moveAside { throw Injected("busy") }
            }
        }
        #expect(folder.marker(app) == "old")
        #expect(folder.marker(staged) == "new")
        #expect(folder.names() == [".App.app.update", "App.app"])
    }

    @Test func aFailedRestoreKeepsThePreviousCopyAndSaysWhere() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let staged = try folder.staged("new", for: app)
        let previous = UpdateSwap.previousLocation(for: app)
        // The second move fails, and meanwhile something else took the app's place, so the restore fails too.
        let error = #expect(throws: UpdateSwap.Failure.self) {
            try UpdateSwap.swap(app: app, staged: staged, atomic: false) { step in
                if step == .moveIn {
                    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
                    throw Injected("disk full")
                }
            }
        }
        guard case .restore(let moveIn, _, let at)? = error else {
            Issue.record("expected a restore failure, got \(String(describing: error))")
            return
        }
        #expect(moveIn == "disk full")
        #expect(at == previous)
        // Nothing was deleted: the old app still exists at the named location, and so does the new one.
        #expect(folder.marker(previous) == "old")
        #expect(folder.marker(staged) == "new")
        #expect(error?.errorDescription?.contains(previous.path) == true)
    }

    @Test func aProcessKilledBetweenTheTwoMovesIsRecoveredAtTheNextLaunch() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        let previous = UpdateSwap.previousLocation(for: app)
        let marker = UpdateSwap.markerLocation(for: app)
        let fileManager = FileManager.default

        // Killed right after the first move: the marker is there, the app is not.
        var staged = try folder.staged("new", for: app)
        #expect(throws: (any Error).self) {
            try UpdateSwap.swap(app: app, staged: staged, atomic: false) { step in
                if step == .moveIn { throw Killed() }
            }
        }
        // `swap` restored the app on the injected failure; undo that to model a real kill.
        try fileManager.moveItem(at: app, to: previous)
        fileManager.createFile(atPath: marker.path, contents: nil)
        #expect(!fileManager.fileExists(atPath: app.path))
        UpdateSwap.recover(app: app)
        #expect(folder.marker(app) == "old")
        #expect(folder.names() == ["App.app"])
        #expect(!fileManager.fileExists(atPath: staged.path))

        // Killed right after the second move, before cleaning up.
        staged = try folder.staged("new", for: app)
        try fileManager.moveItem(at: app, to: previous)
        try fileManager.moveItem(at: staged, to: app)
        fileManager.createFile(atPath: marker.path, contents: nil)
        UpdateSwap.recover(app: app)
        #expect(folder.marker(app) == "new")
        #expect(folder.names() == ["App.app"])

        // Killed right after an atomic exchange, before cleaning up: the old app sits in staging.
        staged = try folder.staged("newer", for: app)
        try UpdateSwap.swap(app: app, staged: staged, atomic: true) { _ in
            // Model the kill by skipping cleanup: recreate the staging folder after the swap.
        }
        _ = try folder.staged("stale old copy", for: app)
        UpdateSwap.recover(app: app)
        #expect(folder.marker(app) == "newer")
        #expect(folder.names() == ["App.app"])

        // Nothing to recover: nothing changes.
        UpdateSwap.recover(app: app)
        #expect(folder.marker(app) == "newer")
    }

    @Test func aLeftoverPreviousCopyIsClearedBeforeAFallbackSwap() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "old")
        try folder.bundle(UpdateSwap.previousLocation(for: app).lastPathComponent, marker: "stale")
        let staged = try folder.staged("new", for: app)
        try UpdateSwap.swap(app: app, staged: staged, atomic: false)
        #expect(folder.marker(app) == "new")
        #expect(folder.names() == ["App.app"])
    }

    struct Killed: Error {}
}
