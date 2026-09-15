import Foundation
import OpenReactionCore
import Testing

private final class MemoryFlags: FlagStore {
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
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
}

@Suite("Login item default")
struct LoginItemDefaultTests {
    @Test func freshInstallRegistersOnce() {
        let store = MemoryFlags()
        let launch = LoginItemDefault(store: store)
        #expect(launch.shouldRegister(isRegistered: false, storageIsFresh: true))
        #expect(store.values[LoginItemDefault.Key.applied] == true)
        // Turned off later (Settings or System Settings): the next launches leave it off.
        let next = LoginItemDefault(store: store)
        #expect(!next.shouldRegister(isRegistered: false, storageIsFresh: true))
        #expect(!next.shouldRegister(isRegistered: false, storageIsFresh: true))
    }

    @Test func storageStillUnknownDecidesNothing() {
        let store = MemoryFlags()
        let launch = LoginItemDefault(store: store)
        #expect(!launch.shouldRegister(isRegistered: false, storageIsFresh: nil))
        #expect(store.values[LoginItemDefault.Key.applied] == nil, "not decided yet")
        #expect(launch.shouldRegister(isRegistered: false, storageIsFresh: true))
    }

    @Test func upgradeWithPreferencesAndLoginOffIsLeftAlone() {
        // An earlier version showed the guide (and never wrote the flag).
        let store = MemoryFlags()
        OnboardingLaunch.markShown(store: store)
        let launch = LoginItemDefault(store: store)
        #expect(launch.hadPreferences)
        #expect(!launch.shouldRegister(isRegistered: false, storageIsFresh: true))
        #expect(store.values[LoginItemDefault.Key.applied] == true, "decided: never again")
        #expect(!LoginItemDefault(store: store).shouldRegister(isRegistered: false, storageIsFresh: true))
    }

    @Test func preferencesWrittenByThisLaunchDoNotCount() {
        // The guide opens (and records itself) before storage answers.
        let store = MemoryFlags()
        let launch = LoginItemDefault(store: store)
        OnboardingLaunch.markShown(store: store)
        #expect(launch.shouldRegister(isRegistered: false, storageIsFresh: true))
    }

    @Test func anExplicitChoiceWhileStorageIsPendingIsNeverUndone() {
        // Fresh launch, Keychain slow: the user turns the item on and off in
        // Settings before storage answers; when it then says "fresh", the
        // default must not turn it back on.
        let store = MemoryFlags()
        let launch = LoginItemDefault(store: store)
        #expect(!launch.shouldRegister(isRegistered: false, storageIsFresh: nil))
        #expect(!launch.isDecided)
        launch.markSuperseded() // on
        launch.markSuperseded() // off again
        #expect(launch.isDecided)
        #expect(!launch.shouldRegister(isRegistered: false, storageIsFresh: true))
        #expect(!LoginItemDefault(store: store).shouldRegister(isRegistered: false, storageIsFresh: true))
    }

    @Test func aKeptTrialOrLicenseRecordMeansNotFresh() {
        let store = MemoryFlags()
        let launch = LoginItemDefault(store: store)
        #expect(!launch.shouldRegister(isRegistered: false, storageIsFresh: false))
        #expect(store.values[LoginItemDefault.Key.applied] == true)
    }

    @Test func anAlreadyRegisteredItemNeedsNothing() {
        let store = MemoryFlags()
        #expect(!LoginItemDefault(store: store).shouldRegister(isRegistered: true, storageIsFresh: true))
        #expect(store.values[LoginItemDefault.Key.applied] == true)
    }
}

/// What the license manager reports as "fresh install", with the licensing fakes.
extension LicensingTests {
    @Test("Fresh install: no license record and no trial record at the first read")
    func freshInstallWhenBothRecordsAreAbsent() {
        trialStore.record = nil
        let manager = makeManager()
        #expect(manager.freshInstall == true)
        #expect(manager.snapshot.freshInstall == true)
        // The provisional trial saved just now does not change the answer.
        #expect(trialStore.record != nil)
        #expect(manager.snapshot.freshInstall == true)
    }

    @Test("Not fresh: a kept trial record (a reinstall) or a license record")
    func notFreshWithAnyRecord() {
        let manager = makeManager() // the default fake trial record: ended long ago
        #expect(manager.freshInstall == false)

        trialStore.record = nil
        store.record = paidRecord(lastSuccessAge: 0)
        let licensed = makeManager()
        #expect(licensed.freshInstall == false)
        #expect(licensed.snapshot.freshInstall == false)
    }

    @Test("Unknown while storage has not answered; decided once it does")
    func freshInstallWaitsForStorage() async {
        trialStore.record = nil
        trialStore.readError = .unavailable("locked")
        let manager = makeManager()
        #expect(manager.freshInstall == nil, "the license record is absent but the trial record is unread")
        trialStore.readError = nil
        await manager.tick()
        #expect(manager.freshInstall == true)

        let locked = MemoryStore()
        locked.failsReads = true
        let other = LicenseManager(
            products: Self.products, client: client, store: locked, journal: journal,
            trialStore: trialStore, registry: registry, device: device, now: { [clock] in clock.now }, uptime: { [clock] in clock.uptime }
        )
        other.load()
        #expect(other.freshInstall == nil, "the license record could not be read")
    }
}
