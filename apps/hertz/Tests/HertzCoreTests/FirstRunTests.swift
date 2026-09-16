import XCTest
@testable import HertzCore

private final class MemoryFlags: FlagStore {
    var bools: [String: Bool] = [:]
    var ints: [String: Int] = [:]
    /// Keys holding something other than a flag (a string, a date), as the
    /// app's other preferences do.
    var otherValues: Set<String> = []
    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func integer(forKey key: String) -> Int { ints[key] ?? 0 }
    func set(_ value: Bool, forKey key: String) { bools[key] = value }
    func set(_ value: Int, forKey key: String) { ints[key] = value }
    func removeObject(forKey key: String) { bools[key] = nil; ints[key] = nil; otherValues.remove(key) }
    func hasValue(forKey key: String) -> Bool { bools[key] != nil || ints[key] != nil || otherValues.contains(key) }
}

/// When the setup guide opens by itself, and where it resumes.
final class OnboardingLaunchTests: XCTestCase {
    @MainActor func testOpensOnTheFirstLaunchOnly() {
        let store = MemoryFlags()
        XCTAssertTrue(OnboardingLaunch.shouldShow(store: store))
        // Deciding to show does not record it; showing does.
        XCTAssertTrue(OnboardingLaunch.shouldShow(store: store))
        OnboardingLaunch.markShown(store: store)
        XCTAssertFalse(OnboardingLaunch.shouldShow(store: store))
    }

    @MainActor func testShowingFromSettingsCountsAsShown() {
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        XCTAssertFalse(OnboardingLaunch.shouldShow(store: store))
    }

    @MainActor func testResumesAtTheFurthestStepReached() {
        let store = MemoryFlags()
        XCTAssertEqual(OnboardingLaunch.resumeStep(store: store), .welcome)
        OnboardingLaunch.markReached(.permissions, store: store)
        OnboardingLaunch.markReached(.loginItem, store: store)
        XCTAssertEqual(OnboardingLaunch.resumeStep(store: store), .loginItem)
        // Going back to re-read a step keeps the progress.
        OnboardingLaunch.markReached(.welcome, store: store)
        XCTAssertEqual(OnboardingLaunch.resumeStep(store: store), .loginItem)
        OnboardingLaunch.markReached(.tips, store: store)
        XCTAssertEqual(OnboardingLaunch.resumeStep(store: store), .tips)
        XCTAssertTrue(GuideStep.tips.isLast)
    }

    @MainActor func testAnUnknownSavedStepStartsOver() {
        let store = MemoryFlags()
        store.set(42, forKey: OnboardingLaunch.Key.step)
        XCTAssertEqual(OnboardingLaunch.resumeStep(store: store), .welcome)
    }

    @MainActor func testStepsAreInGuideOrder() {
        XCTAssertEqual(GuideStep.allCases, [.welcome, .permissions, .loginItem, .tips])
        XCTAssertEqual(GuideStep.welcome.next, .permissions)
        XCTAssertEqual(GuideStep.tips.previous, .loginItem)
        XCTAssertNil(GuideStep.welcome.previous)
        XCTAssertNil(GuideStep.tips.next)
    }
}

/// "Open at login" on by default, once, on a demonstrably fresh install.
final class FreshInstallDefaultTests: XCTestCase {
    @MainActor func testFreshInstallTurnsOnOnce() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.loginItem(store: store)
        XCTAssertFalse(sut.hadPreferences)
        XCTAssertTrue(sut.shouldTurnOn(isOn: false, storageIsFresh: true))
        XCTAssertTrue(sut.isDecided)
        // Decided: a later launch, or the same launch asked again, changes nothing.
        XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true))
        XCTAssertFalse(FreshInstallDefault.loginItem(store: store).shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @MainActor func testStorageStillUnknownDecidesNothing() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.loginItem(store: store)
        XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: nil))
        XCTAssertFalse(sut.isDecided, "nil is not an answer; the question stays open")
        XCTAssertTrue(sut.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @MainActor func testAKeptTrialOrLicenseRecordMeansNotFresh() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.loginItem(store: store)
        XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: false))
        XCTAssertTrue(sut.isDecided, "recorded whichever way it went")
    }

    @MainActor func testAnUpgradeFromTheFreeReleasesIsLeftAlone() {
        // 0.1.x wrote these two; either present is an earlier launch, and a
        // login item the user turned off there stays off.
        for legacy in ["didShowWelcome", "didDefaultOpenAtLogin"] {
            let store = MemoryFlags()
            store.set(true, forKey: legacy)
            let sut = FreshInstallDefault.loginItem(store: store)
            XCTAssertTrue(sut.hadPreferences, legacy)
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true), legacy)
            XCTAssertTrue(sut.isDecided, legacy)
        }
    }

    @MainActor func testAStoredFalseToggleIsAnEarlierPreference() {
        let store = MemoryFlags()
        store.set(false, forKey: "showsProcesses")
        let sut = FreshInstallDefault.loginItem(store: store)
        XCTAssertTrue(sut.hadPreferences)
        XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @MainActor func testAnyRetainedAppPreferenceIsAnEarlierLaunch() {
        for key in FreshInstallDefault.Key.earlierPreferenceEvidence {
            let store = MemoryFlags()
            store.otherValues.insert(key)
            XCTAssertTrue(FreshInstallDefault.loginItem(store: store).hadPreferences, key)
        }
    }

    @MainActor func testTheEvidenceListNamesEveryPreferenceTheAppWrites() {
        // Preferences.swift's keys, OnboardingLaunch's, and this default's own flag.
        let expected: Set<String> = [
            "menuBarReadout", "showsDiagnosis", "showsSleepBlockers", "showsProcesses", "showsCleanupScout",
            OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step, FreshInstallDefault.Key.loginItemApplied,
            "didShowWelcome", "didDefaultOpenAtLogin",
        ]
        XCTAssertEqual(Set(FreshInstallDefault.Key.earlierPreferenceEvidence), expected)
    }

    @MainActor func testPreferencesWrittenByThisLaunchDoNotCount() {
        // Created at launch, before the guide or a setting writes anything.
        let store = MemoryFlags()
        let sut = FreshInstallDefault.loginItem(store: store)
        OnboardingLaunch.markShown(store: store)
        store.otherValues.insert("menuBarReadout")
        XCTAssertFalse(sut.hadPreferences)
        XCTAssertTrue(sut.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @MainActor func testAnExplicitChoiceWhileStorageIsPendingIsNeverUndone() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.loginItem(store: store)
        XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: nil))
        sut.markSuperseded() // the user switched it off in the guide meanwhile
        XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @MainActor func testASettingAlreadyOnNeedsNothing() {
        let store = MemoryFlags()
        let sut = FreshInstallDefault.loginItem(store: store)
        XCTAssertFalse(sut.shouldTurnOn(isOn: true, storageIsFresh: true))
        XCTAssertTrue(sut.isDecided)
    }

    @MainActor func testTheLoginItemFlagKeepsItsStoredName() {
        XCTAssertEqual(FreshInstallDefault.Key.loginItemApplied, "loginItem.defaultApplied")
        XCTAssertEqual(FreshInstallDefault.loginItem(store: MemoryFlags()).key, "loginItem.defaultApplied")
    }
}
