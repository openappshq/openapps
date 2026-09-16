import Foundation
@testable import MacPaper
import MacPaperCore
import OpenAppsLicensing
import Testing

/// The pin while the license restricts (design/products/macpaper.md,
/// "Licensing"): keeping a wallpaper an allowed apply already committed is
/// allowed — the recorded, committed, owned file is handed over again,
/// nothing is rendered and nothing new reaches a desktop — and any other
/// candidate is refused: a file the manifest never listed, one listed for
/// another display, a foreign file under an owned name, a prepared file
/// that was never committed.
@Suite("Keeper while restricted")
@MainActor
struct KeeperRestrictedTests {
    func appliedFiles(_ h: AppModelTests.Harness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: h.directory).appliedImages.path)) ?? []).filter { $0.hasSuffix(".png") || $0.hasSuffix(".heic") }.sorted()
    }

    @Test("After the trial ends, the keeper restores the committed file and renders nothing; a new apply still refuses")
    func restoresOnlyTheCommittedFile() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        let access = StateBox(.trial(daysLeft: 1))
        h.license.bind(access: { access.state.isFeatureEnabled }, restriction: { LicenseRestriction.card(for: access.state) }, canBuy: true)
        h.preferences.sameOnAllDisplays = true
        h.model.apply()
        await h.settle()
        let recorded = h.model.appliedState.file(for: 1)!
        let filesBefore = appliedFiles(h)
        #expect(h.desktop.calls.count == 2 && filesBefore == ["1-1.png", "2-1.png"])

        // The trial ends; macOS puts something else on display 1.
        access.state = .trialEnded
        #expect(!h.license.hasAccess())
        let scheduler = ManualScheduler()
        let keeper = DesktopKeeper(model: h.model, preferences: h.preferences, desktop: h.desktop, scheduler: scheduler)
        h.desktop.currentOverride[1] = URL(fileURLWithPath: "/System/Library/Desktop Pictures/x.heic")
        keeper.check(reason: "space")
        scheduler.fire()
        #expect(h.desktop.calls.count == 3, "one desktop call: the restore")
        #expect(h.desktop.calls.last?.url == recorded && h.desktop.calls.last?.display == 1, "the very file that was committed")
        #expect(appliedFiles(h) == filesBefore, "nothing rendered or written")
        #expect(keeper.lastReport == "space: re-applied 1")
        #expect(h.model.appliedState.file(for: 1) == recorded && h.model.appliedState.file(for: 2) != nil)
        // A new apply is still refused, and the keeper has nothing new to hand over.
        h.model.apply()
        await h.settle()
        #expect(h.desktop.calls.count == 3 && h.model.status?.text == AppModel.restrictedMessage)
        #expect(appliedFiles(h) == filesBefore)
    }

    @Test("Candidates the keeper refuses: unlisted, another display's, a foreign file under an owned name, a prepared file never committed")
    func refusesEverythingButCommittedOwnedFiles() async throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        let access = StateBox(.trial(daysLeft: 1))
        h.license.bind(access: { access.state.isFeatureEnabled }, restriction: { LicenseRestriction.card(for: access.state) }, canBuy: true)
        h.preferences.sameOnAllDisplays = true
        h.model.apply()
        await h.settle()
        let applied = AppPaths(root: h.directory).appliedImages
        let display2File = h.model.appliedState.file(for: 2)!
        // Prepared for display 1 but never committed: in the manifest, not committed.
        let prepared = try h.model.applier.prepare([AppModelTests.Harness.displays[0]: .starter.reseeded(9)])
        let uncommitted = prepared.images[0].url
        // A foreign file under an owned name: the committed file replaced by a symlink.
        let ownedName = h.model.appliedState.file(for: 1)!
        try FileManager.default.removeItem(at: ownedName)
        let outside = h.directory.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: ownedName, withDestinationURL: outside)
        // A file the manifest never listed.
        let unlisted = applied.appendingPathComponent("1-99.png")
        try Data("planted".utf8).write(to: unlisted)

        access.state = .trialEnded
        let callsBefore = h.desktop.calls.count
        for (candidate, display) in [(unlisted, DisplayID(1)), (display2File, 1), (ownedName, 1), (uncommitted, 1)] {
            #expect(throws: WallpaperApplier.ApplyError.notOwned, "\(candidate.lastPathComponent) for \(display)") {
                try h.model.applier.reapply(candidate, to: display)
            }
        }
        #expect(h.desktop.calls.count == callsBefore)
        // Through the keeper, with the uncommitted file planted as display
        // 1's record (a state no normal path produces, since records come
        // only from commits): refused, nothing handed over.
        try h.model.applied.update { state in
            state.record(AppliedImage(display: 1, wallpaper: .starter, url: uncommitted, format: .still), perSpace: false)
        }
        h.model.reloadAppliedState()
        let scheduler = ManualScheduler()
        let keeper = DesktopKeeper(model: h.model, preferences: h.preferences, desktop: h.desktop, scheduler: scheduler)
        h.desktop.currentOverride[1] = URL(fileURLWithPath: "/System/Library/Desktop Pictures/x.heic")
        keeper.check(reason: "space")
        scheduler.fire()
        #expect(h.desktop.calls.count == callsBefore)
        #expect(keeper.lastReport.contains("failed 1:"))
        // The committed file for display 2 is still a valid candidate.
        h.desktop.currentOverride[2] = URL(fileURLWithPath: "/System/Library/Desktop Pictures/y.heic")
        keeper.check(reason: "space")
        scheduler.fire()
        #expect(h.desktop.calls.last?.url == display2File && h.desktop.calls.last?.display == 2)
    }
}
