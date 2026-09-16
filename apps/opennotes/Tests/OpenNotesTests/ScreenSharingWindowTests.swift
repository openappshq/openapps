import AppKit
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// The controller path of "Hide notes from screen sharing" on All Notes:
/// the window takes `.none` while the setting is on, and — a window once
/// hidden can never be shown again — turning the setting off replaces it
/// with a new one that is shared. The window is made but never ordered
/// front, so nothing appears on screen; the deck's decks follow the same
/// `ScreenSharing.apply` verdict through `DeckHost`, which is not run here
/// because its panels would be shown.
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
        return (AllNotesWindowController(model: model, openNote: { _ in }), preferences)
    }

    /// The observation fires on the next main-queue turn.
    @MainActor private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor func testAWindowMadeWithTheSettingOnIsHidden() {
        let (controller, preferences) = makeController()
        preferences.hideFromScreenSharing = true
        controller.makeWindow()
        XCTAssertEqual(controller.window?.sharingType, NSWindow.SharingType.none)
        XCTAssertEqual(controller.window?.isVisible, false, "never shown by a test")
    }

    @MainActor func testTurningTheSettingOnHidesTheOpenWindowInPlace() {
        let (controller, preferences) = makeController()
        controller.makeWindow()
        let original = controller.window
        XCTAssertEqual(original?.sharingType, .readOnly)
        preferences.hideFromScreenSharing = true
        settle()
        XCTAssertTrue(controller.window === original, "hiding needs no new window")
        XCTAssertEqual(controller.window?.sharingType, NSWindow.SharingType.none)
    }

    @MainActor func testTurningTheSettingOffReplacesAHiddenWindowWithASharedOne() {
        let (controller, preferences) = makeController()
        preferences.hideFromScreenSharing = true
        controller.makeWindow()
        let hidden = controller.window
        XCTAssertEqual(hidden?.sharingType, NSWindow.SharingType.none)
        preferences.hideFromScreenSharing = false
        settle()
        XCTAssertNotNil(controller.window)
        XCTAssertFalse(controller.window === hidden, "a new window, the old one being hidden for its life")
        XCTAssertEqual(controller.window?.sharingType, .readOnly)
        XCTAssertEqual(hidden?.sharingType, NSWindow.SharingType.none)
        XCTAssertEqual(controller.window?.isVisible, false, "the old one was not up, so neither is the new")
    }
}
