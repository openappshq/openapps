import AppKit
import Foundation
import OpenReactionCore
import Testing
@testable import OpenReaction

/// The drag-to-grant helper's show and hide rules, apart from its panel.
@Suite("Permission helper model")
struct PermissionHelperModelTests {
    @Test func showsForAPermissionThatIsNotGranted() {
        var model = PermissionHelperModel()
        let shown = model.show(.accessibility, granted: [])
        #expect(shown)
        #expect(model.isShown)
        #expect(model.kind == .accessibility)
    }

    @Test func neverShowsForAGrantedPermission() {
        var model = PermissionHelperModel()
        let shownForGranted = model.show(.accessibility, granted: [.accessibility])
        #expect(!shownForGranted)
        #expect(!model.isShown)
        // Nor does a refused request disturb what is shown.
        model.show(.inputMonitoring, granted: [.accessibility])
        let shownAgain = model.show(.accessibility, granted: [.accessibility])
        #expect(!shownAgain)
        #expect(model.kind == .inputMonitoring)
    }

    @Test func switchesToTheLatestPermissionAsked() {
        var model = PermissionHelperModel()
        model.show(.accessibility, granted: [])
        model.show(.inputMonitoring, granted: [])
        #expect(model.kind == .inputMonitoring)
    }

    @Test func hidesOnceItsPermissionIsGranted() {
        var model = PermissionHelperModel()
        model.show(.inputMonitoring, granted: [])
        let hidOnOther = model.permissionsChanged(granted: [.accessibility])
        #expect(!hidOnOther)
        #expect(model.isShown)
        let hidOnOwn = model.permissionsChanged(granted: [.accessibility, .inputMonitoring])
        #expect(hidOnOwn)
        #expect(!model.isShown)
        // Only the moment it hides is reported.
        let hidAgain = model.permissionsChanged(granted: [.accessibility, .inputMonitoring])
        #expect(!hidAgain)
    }

    @Test func staysOnItsOwnStepAndLeavesWithIt() {
        var model = PermissionHelperModel()
        model.show(.accessibility, granted: [])
        let leftOwnStep = model.guideMoved(to: .accessibility)
        #expect(!leftOwnStep)
        #expect(model.isShown)
        let leftOnNextStep = model.guideMoved(to: .inputMonitoring)
        #expect(leftOnNextStep)
        #expect(!model.isShown)
        let leftAgain = model.guideMoved(to: .tryIt)
        #expect(!leftAgain)
    }

    @Test func leavesWhenTheGuideMovesOffPermissions() {
        var model = PermissionHelperModel()
        model.show(.inputMonitoring, granted: [])
        let left = model.guideMoved(to: .tryIt)
        #expect(left)
        #expect(!model.isShown)
    }

    @Test func closes() {
        var model = PermissionHelperModel()
        model.show(.accessibility, granted: [])
        model.close()
        #expect(!model.isShown)
        #expect(model == PermissionHelperModel())
    }
}

/// What the helper's icon puts on the pasteboard.
@Suite("Permission helper drag")
struct PermissionHelperDragTests {
    @Test func dragsTheRunningAppBundle() {
        #expect(AppDragPayload.app.url == Bundle.main.bundleURL)
    }

    @Test func pasteboardItemIsTheBundleFileURL() {
        let url = URL(fileURLWithPath: "/Applications/OpenReaction.app", isDirectory: true)
        let item = AppDragPayload(url: url).pasteboardItem()
        #expect(item.types == [.fileURL])
        #expect(item.string(forType: .fileURL) == url.absoluteString)
        #expect(item.string(forType: .fileURL).flatMap(URL.init(string:)) == url)
    }

    /// A private pasteboard round trip, the way a drop target reads it.
    @Test func dropTargetReadsAFileURL() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("space.openapps.openreaction.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let payload = AppDragPayload.app
        #expect(pasteboard.writeObjects([payload.pasteboardItem()]))
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(read == [payload.url])
    }

    @MainActor
    @Test func iconTakesTheFirstClickWithoutMovingThePanel() {
        let view = AppIconDragView(payload: .app, image: NSImage(size: NSSize(width: 64, height: 64)))
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.mouseDownCanMoveWindow)
    }
}
