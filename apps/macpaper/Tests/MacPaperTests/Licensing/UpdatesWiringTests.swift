import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// What every build shows about updates: nothing, until an official build
/// binds the updater.
@Suite("Update status in every build")
@MainActor
struct UpdateStatusTests {
    @Test func anUnboundStatusHintsNothing() {
        let status = UpdateStatus()
        #expect(status.hint() == nil)
        var installed = 0
        var restarted = 0
        status.bind(hint: { .ready(version: "0.2.1") }, install: { installed += 1 }, restart: { restarted += 1 })
        #expect(status.hint() == .ready(version: "0.2.1"))
        status.install()
        status.restart()
        #expect(installed == 1 && restarted == 1)
    }

    @Test func theRowNamesTheUpdateAndItsOneAction() {
        #expect(UpdateCopy.line(for: .available(version: "0.2.1")) == "macPaper 0.2.1 available")
        #expect(UpdateCopy.action(for: .available(version: "0.2.1")) == "Install")
        #expect(UpdateCopy.line(for: .downloading(version: "0.2.1")) == "Downloading 0.2.1…")
        #expect(UpdateCopy.action(for: .downloading(version: "0.2.1")) == nil)
        #expect(UpdateCopy.line(for: .ready(version: "0.2.1")) == "Update ready")
        #expect(UpdateCopy.action(for: .ready(version: "0.2.1")) == "Restart")
        #expect(UpdateHint.ready(version: "0.2.1").version == "0.2.1")
    }

    @Test("The model's status is what the panel reads; a source build never binds it")
    func theModelCarriesTheStatus() {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        #expect(h.model.updates.hint() == nil)
        #expect(!UpdateTesting.isCompiledIn || Updating.isCompiledIn, "an update-test build is an official build")
        #expect(!(UpdateTesting.isCompiledIn && Licensing.isCompiledIn), "and never a licensed one")
    }
}

#if OPENAPPS_OFFICIAL
import OpenAppsUpdater

private final class UpdaterMemoryFlags: FlagStore, @unchecked Sendable {
    var bools: [String: Bool] = [:]
    var ints: [String: Int] = [:]
    var otherValues: Set<String> = []
    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func integer(forKey key: String) -> Int { ints[key] ?? 0 }
    func set(_ value: Bool, forKey key: String) { bools[key] = value }
    func set(_ value: Int, forKey key: String) { ints[key] = value }
    func removeObject(forKey key: String) { bools[key] = nil; ints[key] = nil; otherValues.remove(key) }
    func hasValue(forKey key: String) -> Bool { bools[key] != nil || ints[key] != nil || otherValues.contains(key) }
}

/// The app's wiring of the shared updater (RELEASES.md, "In-app updater"):
/// the fresh-install default for "Check for updates automatically", decided
/// once through the same rule as "Open at login", and what the panel's row
/// makes of each phase. The updater is never started, so nothing here contacts a
/// feed; its toggles live in a temporary suite that is removed again.
@Suite("Updater wiring", .serialized)
@MainActor
struct UpdatesWiringTests {
    private func makeUpdates(flags: UpdaterMemoryFlags) throws -> (Updates, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-updates-wiring-\(UUID().uuidString)", isDirectory: true)
        let bundle = directory.appendingPathComponent("macPaper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let temporary = try TemporaryDefaults()
        let configuration = UpdaterConfiguration(
            appID: Updating.appID, appName: Updating.appName, bundleURL: bundle,
            currentVersion: UpdateVersion("0.2.0")!, currentBuild: UpdateVersion("0.2.0")!.buildNumber,
            feedURL: URL(string: "https://openapps.space/updates/macpaper/appcast.xml")!,
            publicKey: Data(repeating: 7, count: 32).base64EncodedString(), defaults: temporary.defaults
        )
        let updates = Updates(updater: Updater(configuration: configuration), flags: flags)
        return (updates, {
            temporary.remove()
            try? FileManager.default.removeItem(at: directory)
        })
    }

    @Test func aFreshInstallTurnsChecksOnOnceStorageAnswers() throws {
        let flags = UpdaterMemoryFlags()
        let (updates, cleanup) = try makeUpdates(flags: flags)
        defer { cleanup() }
        #expect(!updates.updater.checksAutomatically, "nothing stored reads as off")
        #expect(!updates.updater.installsAutomatically)

        updates.applyCheckDefaultIfNeeded(storageIsFresh: nil)
        #expect(!updates.updater.checksAutomatically, "storage has not answered: nothing decided")
        #expect(flags.bools[FreshInstallDefault.Key.updateChecksApplied] == nil)

        updates.applyCheckDefaultIfNeeded(storageIsFresh: true)
        #expect(updates.updater.checksAutomatically)
        #expect(!updates.updater.installsAutomatically, "installing has no default: opt-in")
        #expect(flags.bools[FreshInstallDefault.Key.updateChecksApplied] == true, "decided, never again")

        // Turned off later: the same launch asked again leaves it off.
        updates.updater.setChecksAutomatically(false)
        updates.applyCheckDefaultIfNeeded(storageIsFresh: true)
        #expect(!updates.updater.checksAutomatically)
    }

    @Test func aKeptRecordOrEarlierPreferencesLeaveTheToggleAlone() throws {
        // A reinstall over kept records is not fresh.
        let kept = UpdaterMemoryFlags()
        let (overRecords, cleanupRecords) = try makeUpdates(flags: kept)
        defer { cleanupRecords() }
        overRecords.applyCheckDefaultIfNeeded(storageIsFresh: false)
        #expect(!overRecords.updater.checksAutomatically)
        #expect(kept.bools[FreshInstallDefault.Key.updateChecksApplied] == true, "recorded whichever way it went")

        // An upgrade: the login item was decided by an earlier version, so
        // the check default is owed a decision but no change.
        let upgraded = UpdaterMemoryFlags()
        upgraded.set(true, forKey: FreshInstallDefault.Key.loginItemApplied)
        let (upgrade, cleanupUpgrade) = try makeUpdates(flags: upgraded)
        defer { cleanupUpgrade() }
        upgrade.applyCheckDefaultIfNeeded(storageIsFresh: true)
        #expect(!upgrade.updater.checksAutomatically)
        #expect(upgraded.bools[FreshInstallDefault.Key.updateChecksApplied] == true)
    }

    @Test func anExplicitChoiceWhileStorageIsPendingWins() throws {
        // The user turns checks on and off in Settings before storage has
        // answered; "fresh" arriving afterwards must not turn them back on.
        let flags = UpdaterMemoryFlags()
        let (updates, cleanup) = try makeUpdates(flags: flags)
        defer { cleanup() }
        updates.applyCheckDefaultIfNeeded(storageIsFresh: nil)
        updates.setChecksAutomatically(true)
        #expect(updates.updater.checksAutomatically)
        #expect(flags.bools[FreshInstallDefault.Key.updateChecksApplied] == true, "recorded before the switch")
        updates.setChecksAutomatically(false)
        #expect(!updates.updater.checksAutomatically)
        updates.applyCheckDefaultIfNeeded(storageIsFresh: true)
        #expect(!updates.updater.checksAutomatically)
    }

    @Test func turningChecksOffTurnsInstallingOffToo() throws {
        let flags = UpdaterMemoryFlags()
        let (updates, cleanup) = try makeUpdates(flags: flags)
        defer { cleanup() }
        updates.setChecksAutomatically(true)
        updates.updater.setInstallsAutomatically(true)
        #expect(updates.updater.installsAutomatically)
        updates.setChecksAutomatically(false)
        #expect(!updates.updater.installsAutomatically, "downloading on its own only makes sense while checking on its own")
    }

    @Test func theStatusFollowsTheUpdaterOnceBound() throws {
        let flags = UpdaterMemoryFlags()
        let (updates, cleanup) = try makeUpdates(flags: flags)
        defer { cleanup() }
        let status = UpdateStatus()
        updates.bind(status)
        #expect(status.hint() == nil, "idle: nothing to say")
        #expect(updates.updater.phase == .idle)
    }

    @Test func eachPhaseMapsToTheRowsHint() throws {
        let item = UpdateFeedItem(
            app: Updating.appID, channel: "stable", version: UpdateVersion("0.2.1")!, build: UpdateVersion("0.2.1")!.buildNumber,
            minimumMacOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0), publishedAt: "2026-09-16T10:00:00Z",
            notes: "", url: URL(string: "https://example.invalid/macPaper-0.2.1.zip")!, length: 1, sha256: String(repeating: "0", count: 64), signature: ""
        )
        // `.staged` carries a `StagedUpdate` only the package can make; the
        // end-to-end test (scripts/update-e2e.sh) covers that phase.
        #expect(UpdateHint(phase: .idle) == nil)
        #expect(UpdateHint(phase: .checking) == nil)
        #expect(UpdateHint(phase: .upToDate) == nil)
        #expect(UpdateHint(phase: .failed("x")) == nil)
        #expect(UpdateHint(phase: .available(item)) == .available(version: "0.2.1"))
        #expect(UpdateHint(phase: .downloading(item)) == .downloading(version: "0.2.1"))
    }
}
#endif
