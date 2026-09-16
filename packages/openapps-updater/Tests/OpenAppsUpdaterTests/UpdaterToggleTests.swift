import Foundation
@testable import OpenAppsUpdater
import Testing

/// Stands in for the feed: every request hangs until cancelled, and the
/// protocol counts how many loads started and how many were stopped.
final class HangingFeed: URLProtocol, @unchecked Sendable {
    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var stopped = 0
        var snapshot: (started: Int, stopped: Int) { lock.withLock { (started, stopped) } }
        func didStart() { lock.withLock { started += 1 } }
        func didStop() { lock.withLock { stopped += 1 } }
        func reset() { lock.withLock { started = 0; stopped = 0 } }
    }

    static let counts = Counts()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.counts.didStart() }
    override func stopLoading() { Self.counts.didStop() }
}

@Suite(.serialized) struct UpdaterToggleTests {
    /// A writable bundle path (so the location is updatable), a throwaway
    /// defaults suite (removed again by the cleanup) and the hanging
    /// transport.
    @MainActor
    private func makeUpdater() throws -> (Updater, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openapps-updater-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = directory.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let suite = try TemporaryDefaults()
        let configuration = UpdaterConfiguration(
            appID: "example", appName: "Example", bundleURL: bundle,
            currentVersion: UpdateVersion("1.0.0")!, currentBuild: 1,
            feedURL: URL(string: "https://example.invalid/appcast.xml")!,
            publicKey: Data(repeating: 1, count: 32).base64EncodedString(), defaults: suite.defaults
        )
        let updater = Updater(configuration: configuration, protocolClasses: [HangingFeed.self])
        return (updater, {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    @Test func turningChecksOnAfterStartChecksAtOnceAndOffCancelsIt() async throws {
        HangingFeed.counts.reset()
        let (updater, cleanup) = try makeUpdater()
        defer { cleanup() }
        #expect(updater.location == .updatable)

        updater.start()
        #expect(updater.phase == .idle, "the toggle is off: start() makes no request")
        #expect(HangingFeed.counts.snapshot.started == 0)

        updater.setChecksAutomatically(true)
        #expect(updater.phase == .checking, "never checked: due at once")
        await waitUntil { HangingFeed.counts.snapshot.started == 1 }
        #expect(HangingFeed.counts.snapshot.started == 1)

        updater.setChecksAutomatically(false)
        #expect(updater.phase == .idle)
        await waitUntil { HangingFeed.counts.snapshot.stopped == 1 }
        #expect(HangingFeed.counts.snapshot == (1, 1), "the check in flight was cancelled")
    }

    @MainActor
    @Test func aCancelledCheckOnItsWayOutCannotDisownItsReplacement() async throws {
        // Off then on again before the cancelled check's continuation has
        // run: the replacement starts at once; the old task's cancellation
        // handling must change nothing, and a later off must cancel the
        // replacement, not find the updater idle.
        HangingFeed.counts.reset()
        let (updater, cleanup) = try makeUpdater()
        defer { cleanup() }
        updater.start()

        updater.setChecksAutomatically(true)
        await waitUntil { HangingFeed.counts.snapshot.started == 1 }
        updater.setChecksAutomatically(false)
        updater.setChecksAutomatically(true)
        #expect(updater.phase == .checking, "the replacement check started")
        await waitUntil { HangingFeed.counts.snapshot == (2, 1) }
        #expect(HangingFeed.counts.snapshot == (2, 1))

        // Let the first task's cancellation continuation run.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(updater.phase == .checking, "the stale task left the replacement's phase alone")

        updater.setChecksAutomatically(false)
        #expect(updater.phase == .idle)
        await waitUntil { HangingFeed.counts.snapshot.stopped == 2 }
        #expect(HangingFeed.counts.snapshot == (2, 2), "off cancelled the live replacement")
    }

    @MainActor
    @Test func turningChecksOnBeforeStartMakesNoRequest() async throws {
        // Recovery has not run yet; the launch check belongs to start().
        HangingFeed.counts.reset()
        let (updater, cleanup) = try makeUpdater()
        defer { cleanup() }
        updater.setChecksAutomatically(true)
        #expect(updater.phase == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(HangingFeed.counts.snapshot.started == 0)
        updater.setChecksAutomatically(false)
    }
}
