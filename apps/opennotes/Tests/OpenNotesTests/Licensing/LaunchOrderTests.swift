import Foundation
@testable import OpenNotes
import OpenNotesCore
import OpenAppsLicensing
import Testing

/// The regression for review 1's P0: an official launch used to call
/// `model.start()` (and so its auto-archive sweep) before `startLicensing()`
/// ever bound `licenseStatus`, against a `LicenseStatus()` that answered
/// `hasAccess() == true` until bound. `AppDelegate.swift` now calls
/// `startLicensing()` first, and `LicenseStatus.init(startsRestricted:)`
/// makes an official build's default answer **restricted** — not merely
/// "unbound and permissive" — until something binds it (Licensing.swift).
///
/// This reproduces the actual pre-binding window with no production
/// clients: an `AppModel` built exactly as `AppDelegate` builds it (the
/// flavour's own default, still-unbound `LicenseStatus`), then
/// `model.start()` — the real launch order — over a temporary folder
/// holding one old, unpinned note with auto-archive on, then a restrictive
/// binding, then a grant.
@Suite("Launch order: nothing writes before licensing is bound")
@MainActor
struct LaunchOrderTests {
    let folder: URL
    let temporary: TemporaryDefaults
    let oldID = NoteID("old")
    let oldModified: Date

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-launch-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        oldModified = Date().addingTimeInterval(-30 * 86_400)
        let old = Note(id: oldID, text: "Old note", order: 0, created: oldModified, modified: oldModified)
        let url = folder.appendingPathComponent(oldID.fileName)
        try Data(FrontMatter.serialize(old).utf8).write(to: url)
        // `NoteStore.parse` takes the later of the front matter's `modified`
        // and the file's own date, so the file's mtime is backed off too.
        try FileManager.default.setAttributes([.modificationDate: oldModified], ofItemAtPath: url.path)
        temporary = try TemporaryDefaults()
    }

    func tearDown(_ model: AppModel?) {
        // The watcher (FSEvents on this temp folder) is torn down with the
        // model before the folder goes; `model` is a `let` in each test, so
        // dropping the last reference here runs its `deinit`.
        _ = model
        try? FileManager.default.removeItem(at: folder)
        temporary.remove()
    }

    private func fileURL() -> URL { folder.appendingPathComponent(oldID.fileName) }
    private func bytes() throws -> Data { try Data(contentsOf: fileURL()) }
    private func mtime() throws -> Date? { try FileManager.default.attributesOfItem(atPath: fileURL().path)[.modificationDate] as? Date }

    /// `AppDelegate`'s own construction order: preferences, then the model
    /// over the given status, auto-archive on.
    func makeModel(status: LicenseStatus) -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        preferences.autoArchiveDays = 7
        return AppModel(preferences: preferences, license: status, store: NoteStore(folder: folder), watcher: FolderWatcher())
    }

    /// The main queue's `observeChanges` re-arms through a `DispatchQueue.main.async`
    /// hop; nothing here awaits otherwise, so this is what actually lets it run.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("The flavour's own default status: an official build never archives before binding and a grant; a source build (always on) archives right at start()")
    func defaultStatusAtLaunch() async throws {
        let bytesBefore = try bytes()
        let mtimeBefore = try mtime()
        let status = LicenseStatus() // exactly AppDelegate's `LicenseStatus()`, unbound
        let model = makeModel(status: status)
        defer { tearDown(model) }
        model.start() // the real launch order: the flavour's default status, then start()

        if Licensing.isCompiledIn {
            #expect(!status.hasAccess())
            #expect(status.state() == .trialUnavailable)
            #expect(status.restriction()?.title == "Starting your free trial…")
            #expect(model.archived.map(\.id).contains(oldID) == false, "an official build starts restricted: nothing archives before binding")
            #expect(try bytes() == bytesBefore)
            #expect(try mtime() == mtimeBefore)

            // Bind a restrictive projection, as the controller would before
            // any grant (an ended trial, a revoked license, unreadable
            // storage — any of them).
            let box = StateBox(.trialEnded)
            status.bind(
                access: { box.state.isFeatureEnabled }, state: { box.state },
                restriction: { LicenseRestriction.card(for: box.state) },
                badge: { LicenseBadge.label(for: box.state, appName: Licensing.appName) }, canBuy: true
            )
            await settle()
            #expect(model.archived.map(\.id).contains(oldID) == false, "still restricted: still nothing")
            #expect(try bytes() == bytesBefore)

            // Grant access: the deferred sweep the license observer owed runs.
            box.state = .trial(daysLeft: 3)
            status.publish()
            await settle()
            #expect(model.archived.map(\.id).contains(oldID), "the deferred sweep ran once bound and granted")
            #expect(try bytes() != bytesBefore)
            #expect(try String(contentsOf: fileURL(), encoding: .utf8).contains("archived: true"))
        } else {
            // A source build's default status is always on: the sweep runs
            // right at `start()`, exactly as it always has.
            #expect(status.hasAccess())
            #expect(model.archived.map(\.id).contains(oldID), "source: always on, so start()'s own sweep archives it immediately")
        }
    }

    @Test("A status explicitly starting restricted never archives before it is bound and granted, in every flavour")
    func explicitlyRestrictedStatusNeverArchivesBeforeBindingOrGrant() async throws {
        let bytesBefore = try bytes()
        let status = LicenseStatus(startsRestricted: true)
        let model = makeModel(status: status)
        defer { tearDown(model) }
        model.start()
        #expect(!status.hasAccess())
        #expect(model.archived.map(\.id).contains(oldID) == false)
        #expect(try bytes() == bytesBefore)

        let box = StateBox(.licensed)
        status.bind(
            access: { box.state.isFeatureEnabled }, state: { box.state },
            restriction: { LicenseRestriction.card(for: box.state) },
            badge: { LicenseBadge.label(for: box.state, appName: Licensing.appName) }, canBuy: true
        )
        await settle()
        #expect(model.archived.map(\.id).contains(oldID), "granted from the first binding: the deferred sweep runs")
    }

    @Test("A status explicitly starting unrestricted (standing in for source) archives right at start(), in every flavour")
    func explicitlyUnrestrictedStatusArchivesAtStart() throws {
        let status = LicenseStatus(startsRestricted: false)
        let model = makeModel(status: status)
        defer { tearDown(model) }
        #expect(status.hasAccess())
        model.start()
        #expect(model.archived.map(\.id).contains(oldID))
    }
}
