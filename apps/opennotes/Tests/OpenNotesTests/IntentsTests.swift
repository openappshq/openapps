import AppIntents
import XCTest
@testable import OpenNotes
@testable import OpenNotesCore
import OpenNotesIntents

/// The Shortcuts actions: parameter mapping to an `AutomationRequest`, and
/// one end-to-end run through `IntentHost.perform` bound to a real `Automation`.
final class IntentsTests: XCTestCase {
    private var folder: URL!
    private var temporary: TemporaryDefaults!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opennotes-intents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary = try TemporaryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        temporary = nil
    }

    @MainActor private func makeModel() -> AppModel {
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.folder = folder
        let model = AppModel(preferences: preferences, license: LicenseStatus(startsRestricted: false), store: NoteStore(folder: folder), watcher: FolderWatcher())
        model.store.load(create: false)
        return model
    }

    // MARK: - Parameter mapping

    @MainActor func testCreateNoteIntentMapsItsParameters() {
        let intent = CreateNoteIntent(text: "a", title: " Hi ", color: .mint)
        XCTAssertEqual(intent.request, .new(text: "a", title: "Hi", color: .mint))
    }

    @MainActor func testCreateNoteIntentWithABlankTitleHasNoTitle() {
        let intent = CreateNoteIntent(text: "a", title: "   ", color: nil)
        XCTAssertEqual(intent.request, .new(text: "a", title: nil, color: nil))
    }

    @MainActor func testCreateNoteIntentWithNoTextAndNoTitleHasNoRequest() {
        XCTAssertNil(CreateNoteIntent(text: "", title: nil, color: nil).request)
    }

    @MainActor func testAppendToNoteIntentMapsItsParameters() {
        XCTAssertEqual(AppendToNoteIntent(title: "T", text: "x").request, .append(title: "T", text: "x"))
    }

    @MainActor func testAppendToNoteIntentWithABlankTitleHasNoRequest() {
        XCTAssertNil(AppendToNoteIntent(title: "   ", text: "x").request)
    }

    @MainActor func testAppendToNoteIntentWithEmptyTextHasNoRequest() {
        XCTAssertNil(AppendToNoteIntent(title: "T", text: "").request)
    }

    @MainActor func testGetNoteTextIntentMapsItsTitle() {
        XCTAssertEqual(GetNoteTextIntent(title: "T").request, .text(title: "T"))
    }

    @MainActor func testOpenNoteIntentTrimsItsTitle() {
        XCTAssertEqual(OpenNoteIntent(title: " T ").request, .open(title: "T"))
    }

    @MainActor func testNoteColorChoiceMapsOntoEveryNoteColor() {
        XCTAssertEqual(NoteColorChoice.allCases.map(\.noteColor), NoteColor.allCases)
    }

    // MARK: - End to end through IntentHost

    @MainActor func testCreateNoteIntentPerformsThroughIntentHost() async throws {
        let model = makeModel()
        let automation = Automation(model: model)
        automation.openNote = { _ in }
        IntentHost.perform = { try automation.perform($0) }
        defer { IntentHost.perform = { _ in throw IntentFailure.notRunning } }
        _ = try await CreateNoteIntent(text: "Hello").perform()
        XCTAssertEqual(model.active.map(\.title), ["Hello"])
    }

    @MainActor func testGetNoteTextIntentPerformsThroughIntentHost() async throws {
        let model = makeModel()
        let automation = Automation(model: model)
        automation.openNote = { _ in }
        IntentHost.perform = { try automation.perform($0) }
        defer { IntentHost.perform = { _ in throw IntentFailure.notRunning } }
        _ = try await CreateNoteIntent(text: "Hello world").perform()
        let result = try await GetNoteTextIntent(title: "Hello world").perform()
        let container = try XCTUnwrap(result as? IntentResultContainer<String, Never, Never, Never>)
        XCTAssertEqual(container.value, "Hello world")
    }

    @MainActor func testCreateNoteIntentThrowsWhileReadOnly() async throws {
        let model = makeModel()
        model.license.bind(access: { false }, restriction: { LicenseRestriction.trialEndedSample }, canBuy: true)
        let automation = Automation(model: model)
        IntentHost.perform = { try automation.perform($0) }
        defer { IntentHost.perform = { _ in throw IntentFailure.notRunning } }
        do {
            _ = try await CreateNoteIntent(text: "Hello").perform()
            XCTFail("expected a throw while read-only")
        } catch {
            // Refused: the automation's readOnly failure surfaces.
        }
    }
}
