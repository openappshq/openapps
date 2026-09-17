import Foundation
@testable import MacPaperCore
import Testing

private typealias MemoryFlags = FirstRunTests.MemoryFlags

/// When the setup guide opens by itself, and where it resumes.
@Suite("Setup guide launch")
struct OnboardingLaunchTests {
    @Test("Opens on the first launch only; deciding to show records nothing, showing does")
    func opensOnTheFirstLaunchOnly() {
        let store = MemoryFlags()
        #expect(OnboardingLaunch.shouldShow(store: store))
        #expect(OnboardingLaunch.shouldShow(store: store))
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }

    @Test("Showing from Settings counts as shown")
    func showingFromSettingsCountsAsShown() {
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }

    @Test("Resumes at the furthest step reached; going back keeps the progress")
    func resumesAtTheFurthestStepReached() {
        let store = MemoryFlags()
        #expect(OnboardingLaunch.resumeStep(store: store) == .welcome)
        OnboardingLaunch.markReached(.permissions, store: store)
        OnboardingLaunch.markReached(.loginItem, store: store)
        #expect(OnboardingLaunch.resumeStep(store: store) == .loginItem)
        OnboardingLaunch.markReached(.welcome, store: store)
        #expect(OnboardingLaunch.resumeStep(store: store) == .loginItem)
        OnboardingLaunch.markReached(.tips, store: store)
        #expect(OnboardingLaunch.resumeStep(store: store) == .tips)
        #expect(GuideStep.tips.isLast)
    }

    @Test("An unknown saved step starts over")
    func anUnknownSavedStepStartsOver() {
        let store = MemoryFlags()
        store.set(42, forKey: OnboardingLaunch.Key.step)
        #expect(OnboardingLaunch.resumeStep(store: store) == .welcome)
    }

    @Test("allCases is declaration order; the walk is welcome, panel, permissions, login, tips, and raw values keep their meaning")
    func stepsAreInGuideOrder() {
        // The raw value is what the flag stores, so it never changes for a
        // step even as the walk order does.
        #expect(GuideStep.allCases == [.welcome, .permissions, .loginItem, .tips, .panel])
        #expect(GuideStep.panel.rawValue == 4)
        #expect(GuideStep.order == [.welcome, .panel, .permissions, .loginItem, .tips])
        #expect(GuideStep.welcome.next == .panel)
        #expect(GuideStep.panel.next == .permissions)
        #expect(GuideStep.permissions.next == .loginItem)
        #expect(GuideStep.loginItem.next == .tips)
        #expect(GuideStep.tips.next == nil)
        #expect(GuideStep.tips.previous == .loginItem)
        #expect(GuideStep.panel.previous == .welcome)
        #expect(GuideStep.welcome.previous == nil)
        #expect(GuideStep.welcome.index == 0 && GuideStep.panel.index == 1 && GuideStep.tips.index == 4)
        #expect(GuideStep.welcome < GuideStep.panel && GuideStep.panel < GuideStep.permissions && GuideStep.permissions < GuideStep.tips)
        #expect(GuideStep.tips.isLast && !GuideStep.panel.isLast)
    }

    @Test("The guide's own flags are earlier-launch evidence for the defaults")
    func flagsAreEvidence() {
        for key in [OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step] {
            #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(key), Comment(rawValue: key))
        }
    }
}

/// "Open at login" and "Check for updates automatically" on by default,
/// once, on a demonstrably fresh install (RELEASES.md, "In-app updater").
/// Both follow one rule under their own flag, so every case runs for each.
@Suite("Fresh-install defaults matrix")
struct FreshInstallDefaultMatrixTests {
    typealias Make = @Sendable (any FlagStore) -> FreshInstallDefault
    static let defaults: [(name: String, key: String, make: Make)] = [
        ("loginItem", FreshInstallDefault.Key.loginItemApplied, { FreshInstallDefault.loginItem(store: $0) }),
        ("updateChecks", FreshInstallDefault.Key.updateChecksApplied, { FreshInstallDefault.updateChecks(store: $0) }),
    ]

    /// Runs `body` once per setting, naming the setting in every failure.
    private func forEachDefault(_ body: (_ make: Make, _ key: String, _ name: Comment) -> Void) {
        for setting in Self.defaults { body(setting.make, setting.key, Comment(rawValue: setting.name)) }
    }

    @Test func freshInstallTurnsOnOnce() {
        forEachDefault { make, key, name in
            let store = MemoryFlags()
            let sut = make(store)
            #expect(!sut.hadPreferences, name)
            #expect(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            #expect(sut.isDecided, name)
            #expect(store.bools[key] == true, name)
            // Decided: a later launch, or the same launch asked again, changes nothing.
            #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            #expect(!make(store).shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @Test func storageStillUnknownDecidesNothing() {
        forEachDefault { make, key, name in
            let store = MemoryFlags()
            let sut = make(store)
            #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: nil), name)
            #expect(!sut.isDecided, "nil is not an answer; the question stays open \(name)")
            #expect(store.bools[key] == nil, name)
            #expect(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @Test func aKeptTrialOrLicenseRecordMeansNotFresh() {
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: false), name)
            #expect(sut.isDecided, "recorded whichever way it went \(name)")
        }
    }

    @Test("A stored false toggle is an earlier preference, whatever its value")
    func aStoredFalseToggleIsAnEarlierPreference() {
        forEachDefault { make, _, name in
            for toggle in [PreferenceKey.notchEnabled, PreferenceKey.favoritesOnly, "OpenAppsUpdater.checkAutomatically"] {
                let store = MemoryFlags()
                store.set(false, forKey: toggle)
                let sut = make(store)
                #expect(sut.hadPreferences, "\(toggle) \(name)")
                #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: true), "\(toggle) \(name)")
                #expect(store.bools[toggle] == false, "\(toggle) untouched \(name)")
            }
        }
    }

    @Test("Any retained app preference is an earlier launch")
    func anyRetainedAppPreferenceIsAnEarlierLaunch() {
        forEachDefault { make, key, name in
            for evidence in FreshInstallDefault.Key.earlierPreferenceEvidence where evidence != key {
                let store = MemoryFlags()
                store.otherValues.insert(evidence)
                let sut = make(store)
                #expect(sut.hadPreferences, "\(evidence) \(name)")
                #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: true), "\(evidence) \(name)")
                #expect(sut.isDecided, "\(evidence): decided \(name)")
            }
            #expect(!make(MemoryFlags()).hadPreferences, name)
        }
    }

    @Test("The evidence list names every preference the app writes")
    func theEvidenceListNamesEveryPreferenceTheAppWrites() {
        // Preferences.swift's keys (PreferenceKey.all), OnboardingLaunch's,
        // the notch hint's, both defaults' flags and the updater's
        // (Updater.Key in packages/openapps-updater).
        let expected = Set(PreferenceKey.all).union([
            OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step,
            NotchHint.Key.launches, NotchHint.Key.used,
            FreshInstallDefault.Key.loginItemApplied, FreshInstallDefault.Key.updateChecksApplied,
            "OpenAppsUpdater.checkAutomatically", "OpenAppsUpdater.installAutomatically", "OpenAppsUpdater.lastCheck",
        ])
        #expect(Set(FreshInstallDefault.Key.earlierPreferenceEvidence) == expected)
    }

    @Test("Preferences written by this launch do not count")
    func preferencesWrittenByThisLaunchDoNotCount() {
        // Created at launch, before the guide, a setting or the updater
        // writes anything.
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            OnboardingLaunch.markShown(store: store)
            store.otherValues.insert(PreferenceKey.hotkey)
            store.otherValues.insert("OpenAppsUpdater.lastCheck")
            #expect(!sut.hadPreferences, name)
            #expect(sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @Test("An explicit choice while storage is pending is never undone")
    func anExplicitChoiceWhileStorageIsPendingIsNeverUndone() {
        // Fresh launch, storage slow: the user flips the setting in the guide
        // or Settings before storage answers; when it then says "fresh", the
        // default must not turn it back on.
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: nil), name)
            sut.markSuperseded() // on
            sut.markSuperseded() // off again
            #expect(sut.isDecided, name)
            #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            #expect(!make(store).shouldTurnOn(isOn: false, storageIsFresh: true), name)
        }
    }

    @Test("An explicit choice before launch is never undone")
    func anExplicitChoiceBeforeLaunchIsNeverUndone() {
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            make(store).markSuperseded()
            let sut = make(store)
            #expect(sut.isDecided, name)
            #expect(sut.hadPreferences, "the flag itself is an earlier launch's preference \(name)")
            #expect(!sut.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            #expect(!sut.shouldTurnOn(isOn: true, storageIsFresh: true), name)
        }
    }

    @Test func aSettingAlreadyOnNeedsNothing() {
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            let sut = make(store)
            #expect(!sut.shouldTurnOn(isOn: true, storageIsFresh: true), name)
            #expect(sut.isDecided, name)
        }
    }

    @Test("A later launch of a fresh install never revisits")
    func aLaterLaunchOfAFreshInstallNeverRevisits() {
        forEachDefault { make, _, name in
            let store = MemoryFlags()
            #expect(make(store).shouldTurnOn(isOn: false, storageIsFresh: true), name)
            OnboardingLaunch.markShown(store: store)
            let second = make(store)
            #expect(second.isDecided, name)
            #expect(!second.shouldTurnOn(isOn: false, storageIsFresh: true), name)
            #expect(!second.shouldTurnOn(isOn: false, storageIsFresh: nil), name)
        }
    }

    @Test("The two defaults are decided independently")
    func theTwoDefaultsAreDecidedIndependently() {
        // Both are created at launch, before either writes: on a fresh
        // install the login item resolving first (and recording its flag)
        // does not make the update check see an earlier launch.
        let store = MemoryFlags()
        let loginItem = FreshInstallDefault.loginItem(store: store)
        let updateChecks = FreshInstallDefault.updateChecks(store: store)
        #expect(loginItem.key != updateChecks.key)
        #expect(loginItem.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(loginItem.isDecided)
        #expect(!updateChecks.isDecided)
        #expect(updateChecks.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(store.bools[FreshInstallDefault.Key.updateChecksApplied] == true)
    }

    @Test("An install that decided only the login item owes the other decision, without turning it on")
    func anUpgradeThatDecidedOnlyTheLoginItemOwesTheOtherDecision() {
        let store = MemoryFlags()
        store.set(true, forKey: FreshInstallDefault.Key.loginItemApplied)
        let updateChecks = FreshInstallDefault.updateChecks(store: store)
        #expect(!updateChecks.isDecided)
        #expect(updateChecks.hadPreferences)
        #expect(!updateChecks.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(updateChecks.isDecided)
    }

    @Test("The flags keep the stored names the other apps use")
    func theFlagsKeepTheirStoredNames() {
        #expect(FreshInstallDefault.Key.loginItemApplied == "loginItem.defaultApplied")
        #expect(FreshInstallDefault.loginItem(store: MemoryFlags()).key == "loginItem.defaultApplied")
        #expect(FreshInstallDefault.Key.updateChecksApplied == "updates.checkDefaultApplied")
        #expect(FreshInstallDefault.updateChecks(store: MemoryFlags()).key == "updates.checkDefaultApplied")
        let store = MemoryFlags()
        store.set(true, forKey: "loginItem.defaultApplied")
        #expect(FreshInstallDefault.loginItem(store: store).isDecided)
        #expect(!FreshInstallDefault.updateChecks(store: store).isDecided)
    }
}
