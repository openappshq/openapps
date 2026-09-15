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
    @Test func registersOnceOnTheFirstLaunch() {
        let store = MemoryFlags()
        #expect(LoginItemDefault.shouldRegister(store: store, isRegistered: false))
        #expect(store.values[LoginItemDefault.Key.applied] == true)
        // Turned off later (Settings or System Settings): the next launches leave it off.
        #expect(!LoginItemDefault.shouldRegister(store: store, isRegistered: false))
        #expect(!LoginItemDefault.shouldRegister(store: store, isRegistered: false))
    }

    @Test func anAlreadyRegisteredItemNeedsNothing() {
        let store = MemoryFlags()
        #expect(!LoginItemDefault.shouldRegister(store: store, isRegistered: true))
        #expect(store.values[LoginItemDefault.Key.applied] == true)
        #expect(!LoginItemDefault.shouldRegister(store: store, isRegistered: false))
    }
}
