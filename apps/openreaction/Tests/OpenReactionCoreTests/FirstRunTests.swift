import Foundation
import OpenReactionCore
import Testing

private final class MemoryFlags: FlagStore {
    var values: [String: Bool] = [:]
    /// Keys holding something other than a flag (data, a date), as the
    /// app's other preferences do.
    var otherValues: Set<String> = []
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil; otherValues.remove(key) }
    func hasValue(forKey key: String) -> Bool { values[key] != nil || otherValues.contains(key) }
}

@Suite("Onboarding launch")
struct OnboardingLaunchTests {
    @Test func opensOnTheFirstLaunchOnly() {
        let store = MemoryFlags()
        #expect(OnboardingLaunch.shouldShow(store: store))
        // Deciding to show does not record it; showing does.
        #expect(OnboardingLaunch.shouldShow(store: store))
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }

    @Test func showingFromSettingsCountsAsShown() {
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }

    @Test func resumesOnceAfterARelaunchItStarted() {
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        OnboardingLaunch.markResumeAfterRelaunch(store: store)
        #expect(OnboardingLaunch.shouldShow(store: store))
        #expect(!OnboardingLaunch.shouldShow(store: store), "the marker is consumed")
        #expect(store.values[OnboardingLaunch.Key.resumeAfterRelaunch] == nil)
    }

    @Test func incompleteSetupDoesNotReopenIt() {
        // Setup state is not an input: the status menu's badge and
        // "Finish Setup…" carry an unfinished setup.
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }

    @Test func resumesOnceAfterMacOSReopensItWhileAwaitingAPermission() {
        // The window asked for a permission; granting it ended with macOS's
        // own "Quit & Reopen", which never set the relaunch marker.
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        OnboardingLaunch.markAwaitingPermission(store: store)
        #expect(OnboardingLaunch.shouldShow(store: store))
        #expect(!OnboardingLaunch.shouldShow(store: store), "the marker is consumed")
        #expect(store.values[OnboardingLaunch.Key.awaitingPermission] == nil)
    }

    @Test func closingTheWindowAfterAskingDoesNotReopenIt() {
        // Asked for a permission, then skipped or closed the window: the
        // user's dismissal wins over the pending request. Which closes count
        // as a dismissal (skip, finish, the close button — never a quit's
        // close of every window) is AppKit delegate routing in the app
        // target, not expressible here.
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        OnboardingLaunch.markAwaitingPermission(store: store)
        OnboardingLaunch.clearAwaitingPermission(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
        #expect(store.values[OnboardingLaunch.Key.awaitingPermission] == nil)
    }

    @Test func bothMarkersTogetherOpenItOnce() {
        // Asked for a permission, then pressed Relaunch: one window, and
        // neither marker is left behind.
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        OnboardingLaunch.markAwaitingPermission(store: store)
        OnboardingLaunch.markResumeAfterRelaunch(store: store)
        #expect(OnboardingLaunch.shouldShow(store: store))
        #expect(!OnboardingLaunch.shouldShow(store: store))
        #expect(store.values[OnboardingLaunch.Key.resumeAfterRelaunch] == nil)
        #expect(store.values[OnboardingLaunch.Key.awaitingPermission] == nil)
    }

    @Test func firstLaunchIsUnchangedByTheMarkers() {
        // Nothing shown yet: the first launch opens it, and a stray marker
        // is consumed rather than counted a second time.
        let store = MemoryFlags()
        OnboardingLaunch.markAwaitingPermission(store: store)
        #expect(OnboardingLaunch.shouldShow(store: store))
        #expect(store.values[OnboardingLaunch.Key.awaitingPermission] == nil)
        #expect(OnboardingLaunch.shouldShow(store: store), "still the first launch until shown")
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }
}

@Suite("Fresh-install defaults")
struct FreshInstallDefaultTests {
    /// Both settings follow one rule under their own flag; the login item
    /// and the update check are the same decision with a different key, so
    /// every case runs for each.
    static let keys = [FreshInstallDefault.Key.loginItemApplied, FreshInstallDefault.Key.updateChecksApplied]

    private func makeDefault(store: MemoryFlags, key: String) -> FreshInstallDefault {
        FreshInstallDefault(store: store, key: key)
    }

    @Test(arguments: Self.keys) func freshInstallTurnsOnOnce(key: String) {
        let store = MemoryFlags()
        let launch = makeDefault(store: store, key: key)
        #expect(launch.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(store.values[key] == true)
        // Turned off later (Settings, or System Settings for the login item): the next launches leave it off.
        let next = makeDefault(store: store, key: key)
        #expect(next.isDecided)
        #expect(!next.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(!next.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @Test(arguments: Self.keys) func storageStillUnknownDecidesNothing(key: String) {
        let store = MemoryFlags()
        let launch = makeDefault(store: store, key: key)
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: nil))
        #expect(store.values[key] == nil, "not decided yet")
        #expect(!launch.isDecided)
        #expect(launch.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @Test(arguments: Self.keys) func upgradeWithPreferencesAndTheSettingOffIsLeftAlone(key: String) {
        // An earlier version showed the guide (and never wrote the flag): the
        // user could have set the toggle, so the default records itself as
        // decided without touching it.
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        let launch = makeDefault(store: store, key: key)
        #expect(launch.hadPreferences)
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(store.values[key] == true, "decided: never again")
        #expect(!makeDefault(store: store, key: key).shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @Test(arguments: Self.keys) func aStoredFalseToggleIsAnEarlierPreference(key: String) {
        // Preferences partly kept: the onboarding flag is gone, but the
        // updater's check toggle is stored as off, and the records are
        // absent. The stored value is a choice; the default records itself
        // decided and leaves it.
        let store = MemoryFlags()
        store.set(false, forKey: "OpenAppsUpdater.checkAutomatically")
        let launch = makeDefault(store: store, key: key)
        #expect(launch.hadPreferences)
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(store.values[key] == true, "decided")
        #expect(store.values["OpenAppsUpdater.checkAutomatically"] == false, "untouched")
    }

    @Test(arguments: Self.keys) func anyRetainedAppPreferenceIsAnEarlierLaunch(key: String) {
        // Each key the app writes counts on its own, whatever it holds.
        for evidence in FreshInstallDefault.Key.earlierPreferenceEvidence where evidence != key {
            let store = MemoryFlags()
            store.otherValues.insert(evidence)
            let launch = makeDefault(store: store, key: key)
            #expect(launch.hadPreferences, "\(evidence)")
            #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: true), "\(evidence)")
            #expect(store.values[key] == true, "\(evidence): decided")
        }
        let empty = MemoryFlags()
        #expect(!makeDefault(store: empty, key: key).hadPreferences)
    }

    @Test func theEvidenceListNamesEveryPreferenceTheAppWrites() {
        // The keys the app and the updater write to the standard domain, by
        // hand; a new preference belongs here too.
        #expect(Set(FreshInstallDefault.Key.earlierPreferenceEvidence) == [
            "onboarding.shown", "onboarding.resumeAfterRelaunch", "onboarding.awaitingPermission",
            "loginItem.defaultApplied", "updates.checkDefaultApplied",
            "enabled", "frecency", "exclusions", "permissionFlow",
            "OpenAppsUpdater.checkAutomatically", "OpenAppsUpdater.installAutomatically", "OpenAppsUpdater.lastCheck",
        ])
    }

    @Test(arguments: Self.keys) func preferencesWrittenByThisLaunchDoNotCount(key: String) {
        // The guide opens (and records itself) before storage answers.
        let store = MemoryFlags()
        let launch = makeDefault(store: store, key: key)
        OnboardingLaunch.markShown(store: store)
        #expect(launch.shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @Test(arguments: Self.keys) func anExplicitChoiceWhileStorageIsPendingIsNeverUndone(key: String) {
        // Fresh launch, storage slow: the user turns the setting on and off
        // in Settings before storage answers; when it then says "fresh", the
        // default must not turn it back on.
        let store = MemoryFlags()
        let launch = makeDefault(store: store, key: key)
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: nil))
        #expect(!launch.isDecided)
        launch.markSuperseded() // on
        launch.markSuperseded() // off again
        #expect(launch.isDecided)
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(!makeDefault(store: store, key: key).shouldTurnOn(isOn: false, storageIsFresh: true))
    }

    @Test(arguments: Self.keys) func anExplicitChoiceBeforeLaunchIsNeverUndone(key: String) {
        // A toggle set in Settings on an earlier launch whose storage never
        // answered (the flag was recorded then): decided, whatever the value.
        let store = MemoryFlags()
        makeDefault(store: store, key: key).markSuperseded()
        let launch = makeDefault(store: store, key: key)
        #expect(launch.isDecided)
        #expect(launch.hadPreferences, "the flag itself is an earlier launch's preference")
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(!launch.shouldTurnOn(isOn: true, storageIsFresh: true))
    }

    @Test(arguments: Self.keys) func aKeptTrialOrLicenseRecordMeansNotFresh(key: String) {
        let store = MemoryFlags()
        let launch = makeDefault(store: store, key: key)
        #expect(!launch.shouldTurnOn(isOn: false, storageIsFresh: false))
        #expect(store.values[key] == true)
    }

    @Test(arguments: Self.keys) func aSettingAlreadyOnNeedsNothing(key: String) {
        let store = MemoryFlags()
        #expect(!makeDefault(store: store, key: key).shouldTurnOn(isOn: true, storageIsFresh: true))
        #expect(store.values[key] == true)
    }

    @Test(arguments: Self.keys) func aLaterLaunchOfAFreshInstallNeverRevisits(key: String) {
        // Decided on the first launch; a second launch finds the flag and
        // asks nothing, even when storage still reports fresh and the user
        // has since turned the setting off.
        let store = MemoryFlags()
        #expect(makeDefault(store: store, key: key).shouldTurnOn(isOn: false, storageIsFresh: true))
        OnboardingLaunch.markShown(store: store)
        let second = makeDefault(store: store, key: key)
        #expect(second.isDecided)
        #expect(!second.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(!second.shouldTurnOn(isOn: false, storageIsFresh: nil))
    }
}

@Suite("Fresh-install defaults: two settings, two flags")
struct FreshInstallDefaultKeysTests {
    @Test func theTwoDefaultsAreDecidedIndependently() {
        // Deciding one must not decide the other. Both are created at launch,
        // before either writes: on a fresh install the login item resolving
        // first (and recording its flag) does not make the update check see
        // an earlier launch.
        let store = MemoryFlags()
        let loginItem = FreshInstallDefault.loginItem(store: store)
        let updateChecks = FreshInstallDefault.updateChecks(store: store)
        #expect(loginItem.key == FreshInstallDefault.Key.loginItemApplied)
        #expect(updateChecks.key == FreshInstallDefault.Key.updateChecksApplied)
        #expect(loginItem.key != updateChecks.key)

        #expect(loginItem.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(loginItem.isDecided)
        #expect(!updateChecks.isDecided)
        #expect(updateChecks.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(store.values[FreshInstallDefault.Key.updateChecksApplied] == true)
    }

    @Test func anUpgradeThatDecidedOnlyTheLoginItemOwesTheOtherDecision() {
        // An earlier version had only the login-item default: its flag is an
        // earlier launch's preference, so the update check is recorded as
        // decided without turning on.
        let store = MemoryFlags()
        store.set(true, forKey: FreshInstallDefault.Key.loginItemApplied)
        let updateChecks = FreshInstallDefault.updateChecks(store: store)
        #expect(!updateChecks.isDecided)
        #expect(updateChecks.hadPreferences)
        #expect(!updateChecks.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(updateChecks.isDecided)
    }

    @Test func theLoginItemFlagKeepsItsStoredName() {
        // Installs that decided the login item under an earlier version must
        // still read as decided.
        #expect(FreshInstallDefault.Key.loginItemApplied == "loginItem.defaultApplied")
        let store = MemoryFlags()
        store.set(true, forKey: "loginItem.defaultApplied")
        #expect(FreshInstallDefault.loginItem(store: store).isDecided)
        #expect(!FreshInstallDefault.updateChecks(store: store).isDecided)
    }
}
