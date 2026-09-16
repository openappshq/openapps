import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// The controller path of "Keep notes out of screen sharing" on All Notes:
/// the window's `sharingType` is `.none` while the setting is on, and —
/// the setter never raises it again — turning the setting off replaces
/// the window with a new `.readOnly` one, keeping its frame and the
/// user's search, filter and selection. The property, not capture. The
/// window is made but never ordered front and never autosaves its frame,
/// so nothing appears on screen and no defaults domain is written; the
/// decks follow the same `ScreenSharing.apply` verdict through `DeckHost`,
/// which is not run here because its panels would be shown.
final class ScreenSharingWindowTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!
    private var realFolderExistedBefore = false

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-sharing-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
        realFolderExistedBefore = MainActor.assumeIsolated { FileManager.default.fileExists(atPath: NoteStore.defaultFolder().path) }
    }

    override func tearDownWithError() throws {
        if !realFolderExistedBefore {
            let stillMissing = MainActor.assumeIsolated { !FileManager.default.fileExists(atPath: NoteStore.defaultFolder().path) }
            XCTAssertTrue(stillMissing, "must never create ~/Documents/OpenNotes")
        }
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeController() -> (AllNotesWindowController, Preferences) {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder), watcher: FolderWatcher())
        let controller = AllNotesWindowController(model: model, openNote: { _ in })
        // No frame autosave: a test writes nothing to any defaults domain.
        controller.frameAutosaveName = nil
        return (controller, preferences)
    }

    /// The observation fires on the next main-queue turn.
    @MainActor private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor func testAWindowMadeWithTheSettingOnHasSharingTypeNone() {
        let (controller, preferences) = makeController()
        preferences.hideFromScreenSharing = true
        controller.makeWindow()
        XCTAssertEqual(controller.window?.sharingType, NSWindow.SharingType.none)
        XCTAssertEqual(controller.window?.isVisible, false, "never shown by a test")
    }

    @MainActor func testTurningTheSettingOnSetsNoneOnTheOpenWindowInPlace() {
        let (controller, preferences) = makeController()
        controller.makeWindow()
        let original = controller.window
        XCTAssertEqual(original?.sharingType, .readOnly)
        preferences.hideFromScreenSharing = true
        settle()
        XCTAssertTrue(controller.window === original, "hiding needs no new window")
        XCTAssertEqual(controller.window?.sharingType, NSWindow.SharingType.none)
    }

    @MainActor func testTurningTheSettingOffReplacesTheWindowWithAReadOnlyOneKeepingFrameAndState() {
        let (controller, preferences) = makeController()
        preferences.hideFromScreenSharing = true
        controller.makeWindow()
        let hidden = controller.window
        XCTAssertEqual(hidden?.sharingType, NSWindow.SharingType.none)
        // Where the user had it, and what they were looking at.
        let frame = NSRect(x: 120, y: 80, width: 800, height: 600)
        hidden?.setFrame(frame, display: false)
        controller.session.query = "milk"
        controller.session.showsArchived = true
        controller.session.selection = NoteID("groceries")
        preferences.hideFromScreenSharing = false
        settle()
        XCTAssertNotNil(controller.window)
        XCTAssertFalse(controller.window === hidden, "a new window, the old one being hidden for its life")
        XCTAssertEqual(controller.window?.sharingType, .readOnly)
        XCTAssertEqual(hidden?.sharingType, NSWindow.SharingType.none)
        XCTAssertEqual(controller.window?.isVisible, false, "the old one was not up, so neither is the new")
        XCTAssertEqual(controller.window?.frame, frame, "the same place")
        XCTAssertEqual(controller.session.query, "milk")
        XCTAssertTrue(controller.session.showsArchived)
        XCTAssertEqual(controller.session.selection, NoteID("groceries"))
    }
}
