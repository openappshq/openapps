import XCTest
@testable import OpenNotes
@testable import OpenNotesCore

/// "Keep notes out of screen sharing" on once, on a demonstrably fresh
/// install (design/products/opennotes.md, "Settings";
/// Preferences.applyScreenSharingDefaultIfNeeded).
final class ScreenSharingDefaultTests: XCTestCase {
    @MainActor func testAFreshSuiteTurnsItOnOnce() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        XCTAssertFalse(preferences.hideFromScreenSharing)
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: true)
        XCTAssertTrue(preferences.hideFromScreenSharing)
        XCTAssertTrue(temporary.defaults.bool(forKey: FreshInstallDefault.Key.screenSharingApplied))
    }

    @MainActor func testStorageStillUnknownDecidesNothingUntilItAnswers() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: nil)
        XCTAssertFalse(preferences.hideFromScreenSharing)
        XCTAssertFalse(temporary.defaults.bool(forKey: FreshInstallDefault.Key.screenSharingApplied), "nil decides nothing yet")
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: true)
        XCTAssertTrue(preferences.hideFromScreenSharing, "a later answer still turns it on")
    }

    @MainActor func testASuiteWithEarlierPreferencesLeavesItOffButDecided() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set(DeckSide.left.rawValue, forKey: Preferences.Key.side)
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: true)
        XCTAssertFalse(preferences.hideFromScreenSharing)
        XCTAssertTrue(temporary.defaults.bool(forKey: FreshInstallDefault.Key.screenSharingApplied), "decided, so it is never asked again")
    }

    @MainActor func testTheUserTurningItOffBeforeStorageAnswersIsNeverUndone() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.hideFromScreenSharing = false
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: true)
        XCTAssertFalse(preferences.hideFromScreenSharing)
    }

    @MainActor func testASecondPreferencesOverTheSameSuiteReadsTheStoredValueBack() throws {
        let temporary = try TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        preferences.applyScreenSharingDefaultIfNeeded(storageIsFresh: true)
        XCTAssertTrue(Preferences(defaults: temporary.defaults).hideFromScreenSharing)
    }

    @MainActor func testEarlierPreferenceEvidenceListsBothNewKeys() {
        XCTAssertTrue(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(FreshInstallDefault.Key.screenSharingApplied))
        XCTAssertTrue(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(FreshInstallDefault.Key.hideFromScreenSharing))
    }
}
