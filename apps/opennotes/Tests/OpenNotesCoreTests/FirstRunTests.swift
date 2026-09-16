import XCTest
@testable import OpenNotesCore

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

/// "Open at login" and "Check for updates automatically" on by default,
/// once, on a demonstrably fresh install (RELEASES.md, "In-app updater").
/// Both follow one rule under their own flag, so every case runs for each.
final class FreshInstallDefaultTests: XCTestCase {
    private typealias Make = @Sendable (any FlagStore) -> FreshInstallDefault
    private static let defaults: [(name: String, key: String, make: Make)] = [
        ("loginItem", FreshInstallDefault.Key.loginItemApplied, { FreshInstallDefault.loginItem(store: $0) }),
        ("updateChecks", FreshInstallDefault.Key.updateChecksApplied, { FreshInstallDefault.updateChecks(store: $0) }),
    ]

    /// Runs `body` once per setting, naming the setting in every failure.
    private func forEachDefault(_ body: (_ make: Make, _ key: String, _ name: String) -> Void) {
        for setting in Self.defaults { body(setting.make, setting.key, setting.name) }
    }

    @MainActor func testFreshInstallTurnsOnOnce() {
        forEachDefault { make, key, name in
            let store = MemoryFlags()
            let sut = make(store)
            XCTAssertFalse(sut.hadPreferences, name)
            XCTAssertTrue(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            XCTAssertTrue(sut.isDecided, name)
            XCTAssertEqual(store.bools[key], true, name)
            // Decided: a later launch, or the same launch asked again, changes nothing.
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            XCTAssertFalse(make(store).shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @MainActor func testStorageStillUnknownDecidesNothing() {
        forEachDefault { make, key, name in
            let store = MemoryFlags()
            let sut = make(store)
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: nil), name)
            XCTAssertFalse(sut.isDecided, "\(name): nil is not an answer; the question stays open")
            XCTAssertNil(store.bools[key], name)
            XCTAssertTrue(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @MainActor func testAKeptTrialOrLicenseRecordMeansNotFresh() {
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: false), name)
            XCTAssertTrue(sut.isDecided, "\(name): recorded whichever way it went")
        }
    }

    @MainActor func testAStoredFalseToggleIsAnEarlierPreference() {
        // Auto-archive left off, or the updater's check toggle stored as
        // off: a choice, whatever its value, so the default leaves it.
        forEachDefault { make, _, name in
            for toggle in ["notes.autoArchiveDays", "OpenAppsUpdater.checkAutomatically"] {
                let store = MemoryFlags()
                store.set(false, forKey: toggle)
                let sut = make(store)
                XCTAssertTrue(sut.hadPreferences, "\(name): \(toggle)")
                XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true), "\(name): \(toggle)")
                XCTAssertEqual(store.bools[toggle], false, "\(name): \(toggle) untouched")
            }
        }
    }

    @MainActor func testAnyRetainedAppPreferenceIsAnEarlierLaunch() {
        forEachDefault { make, key, name in
            for evidence in FreshInstallDefault.Key.earlierPreferenceEvidence where evidence != key {
                let store = MemoryFlags()
                store.otherValues.insert(evidence)
                let sut = make(store)
                XCTAssertTrue(sut.hadPreferences, "\(name): \(evidence)")
                XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true), "\(name): \(evidence)")
                XCTAssertTrue(sut.isDecided, "\(name): \(evidence): decided")
            }
            XCTAssertFalse(make(MemoryFlags()).hadPreferences, name)
        }
    }

    @MainActor func testTheEvidenceListNamesEveryPreferenceTheAppWrites() {
        // Preferences.swift's keys, OnboardingLaunch's, both defaults' flags
        // and the updater's (Updater.Key in packages/openapps-updater).
        let expected: Set<String> = [
            "deck.side", "deck.display", "hotkey", "notesFolder", "notes.face", "notes.color", "notes.autoArchiveDays",
            OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step,
            FreshInstallDefault.Key.loginItemApplied, FreshInstallDefault.Key.updateChecksApplied,
            "OpenAppsUpdater.checkAutomatically", "OpenAppsUpdater.installAutomatically", "OpenAppsUpdater.lastCheck",
        ]
        XCTAssertEqual(Set(FreshInstallDefault.Key.earlierPreferenceEvidence), expected)
    }

    @MainActor func testPreferencesWrittenByThisLaunchDoNotCount() {
        // Created at launch, before the guide, a setting or the updater
        // writes anything.
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            OnboardingLaunch.markShown(store: store)
            store.otherValues.insert("deck.side")
            store.otherValues.insert("OpenAppsUpdater.lastCheck")
            XCTAssertFalse(sut.hadPreferences, name)
            XCTAssertTrue(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @MainActor func testAnExplicitChoiceWhileStorageIsPendingIsNeverUndone() {
        // Fresh launch, storage slow: the user flips the setting in the guide
        // or Settings before storage answers; when it then says "fresh", the
        // default must not turn it back on.
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: nil), name)
            sut.markSuperseded() // on
            sut.markSuperseded() // off again
            XCTAssertTrue(sut.isDecided, name)
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            XCTAssertFalse(make(store).shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @MainActor func testAnExplicitChoiceBeforeLaunchIsNeverUndone() {
        // A toggle set on an earlier launch whose storage never answered (the
        // flag was recorded then): decided, whatever the value.
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            make(store).markSuperseded()
            let sut = make(store)
            XCTAssertTrue(sut.isDecided, name)
            XCTAssertTrue(sut.hadPreferences, "\(name): the flag itself is an earlier launch's preference")
            XCTAssertFalse(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            XCTAssertFalse(sut.shouldTurnOn(isOn: true, storageIsFresh: true), name)
        }
    }

    @MainActor func testASettingAlreadyOnNeedsNothing() {
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            XCTAssertFalse(sut.shouldTurnOn(isOn: true, storageIsFresh: true), name)
            XCTAssertTrue(sut.isDecided, name)
        }
    }

    @MainActor func testALaterLaunchOfAFreshInstallNeverRevisits() {
        // Decided on the first launch; a second launch finds the flag and
        // asks nothing, even when storage still reports fresh and the user
        // has since turned the setting off.
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            XCTAssertTrue(make(store).shouldTurnOn(isOn: false, storageIsFresh: true), name)
            OnboardingLaunch.markShown(store: store)
            let second = make(store)
            XCTAssertTrue(second.isDecided, name)
            XCTAssertFalse(second.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            XCTAssertFalse(second.shouldTurnOn(isOn: false, storageIsFresh: nil), name)
        }
    }

    @MainActor func testTheTwoDefaultsAreDecidedIndependently() {
        // Deciding one must not decide the other. Both are created at launch,
        // before either writes: on a fresh install the login item resolving
        // first (and recording its flag) does not make the update check see
        // an earlier launch.
        let store = MemoryFlags()
        let loginItem = FreshInstallDefault.loginItem(store: store)
        let updateChecks = FreshInstallDefault.updateChecks(store: store)
        XCTAssertNotEqual(loginItem.key, updateChecks.key)
        XCTAssertTrue(loginItem.shouldTurnOn(isOn: false, storageIsFresh: true))
        XCTAssertTrue(loginItem.isDecided)
        XCTAssertFalse(updateChecks.isDecided)
        XCTAssertTrue(updateChecks.shouldTurnOn(isOn: false, storageIsFresh: true))
        XCTAssertEqual(store.bools[FreshInstallDefault.Key.updateChecksApplied], true)
    }

    @MainActor func testAnUpgradeThatDecidedOnlyTheLoginItemOwesTheOtherDecision() {
        // The licensed release before the updater had only the login-item
        // default: its flag is an earlier launch's preference, so the update
        // check is recorded as decided without turning on.
        let store = MemoryFlags()
        store.set(true, forKey: FreshInstallDefault.Key.loginItemApplied)
        let updateChecks = FreshInstallDefault.updateChecks(store: store)
        XCTAssertFalse(updateChecks.isDecided)
        XCTAssertTrue(updateChecks.hadPreferences)
        XCTAssertFalse(updateChecks.shouldTurnOn(isOn: false, storageIsFresh: true))
        XCTAssertTrue(updateChecks.isDecided)
    }

    @MainActor func testTheFlagsKeepTheirStoredNames() {
        // Installs that decided under an earlier version must still read as
        // decided; the update flag matches OpenReaction's, so the rule reads
        // the same across the apps.
        XCTAssertEqual(FreshInstallDefault.Key.loginItemApplied, "loginItem.defaultApplied")
        XCTAssertEqual(FreshInstallDefault.loginItem(store: MemoryFlags()).key, "loginItem.defaultApplied")
        XCTAssertEqual(FreshInstallDefault.Key.updateChecksApplied, "updates.checkDefaultApplied")
        XCTAssertEqual(FreshInstallDefault.updateChecks(store: MemoryFlags()).key, "updates.checkDefaultApplied")
        let store = MemoryFlags()
        store.set(true, forKey: "loginItem.defaultApplied")
        XCTAssertTrue(FreshInstallDefault.loginItem(store: store).isDecided)
        XCTAssertFalse(FreshInstallDefault.updateChecks(store: store).isDecided)
    }
}
