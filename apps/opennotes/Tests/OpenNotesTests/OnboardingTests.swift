import Foundation
@testable import OpenNotes
import OpenNotesCore
import OpenAppsLicensing
import Testing

final class MemoryFlags: FlagStore, @unchecked Sendable {
    var bools: [String: Bool] = [:]
    var ints: [String: Int] = [:]
    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func integer(forKey key: String) -> Int { ints[key] ?? 0 }
    func set(_ value: Bool, forKey key: String) { bools[key] = value }
    func set(_ value: Int, forKey key: String) { ints[key] = value }
    func removeObject(forKey key: String) { bools[key] = nil; ints[key] = nil }
    func hasValue(forKey key: String) -> Bool { bools[key] != nil || ints[key] != nil }
}

/// A login-item service that registers nothing, for tests: the setup
/// guide's model creates a `LoginItem` regardless of the step it starts on.
private final class InertLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

/// The setup guide's model without its window: the steps, the progress it
/// keeps, and what it says about the license — from the status it is
/// given, never a stored claim.
@Suite("Setup guide model")
@MainActor
struct OnboardingModelTests {
    let flags = MemoryFlags()
    /// Standing in for "nothing bound yet" regardless of flavour: an
    /// official build's own default starts restricted (Licensing.swift),
    /// which is not what most of these tests are about.
    let license = LicenseStatus(startsRestricted: false)

    func makeModel() -> OnboardingModel {
        let temporary = try! TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        return OnboardingModel(loginItem: LoginItem(flags: flags, service: InertLoginItemService()), license: license, preferences: preferences, defaults: flags)
    }

    @Test("Starts at welcome, moves forward and back through files and loginItem, and only records progress forward")
    func stepsAndProgress() {
        let model = makeModel()
        #expect(model.step == .welcome)
        model.getStarted()
        #expect(model.step == .permissions)
        model.advance()
        #expect(model.step == .files)
        model.advance()
        #expect(model.step == .loginItem)
        model.back()
        #expect(model.step == .files)
        #expect(OnboardingLaunch.resumeStep(store: flags) == .loginItem, "going back keeps the progress")
        model.advance()
        model.advance()
        #expect(model.step == .tips && model.step.isLast)
        model.advance()
        #expect(model.step == .tips)
        // A second run resumes where the first left off.
        #expect(makeModel().step == .tips)
    }

    @Test("Skip and Done close; the closing hands off to the window")
    func closing() {
        let model = makeModel()
        var closed = 0
        model.onClose = { closed += 1 }
        model.skip()
        model.finish()
        #expect(closed == 2)
        #expect(!flags.bool(forKey: OnboardingLaunch.Key.shown), "the model never marks the guide shown; the window does")
    }

    @Test("Showing resumes at the saved step and reports visibility")
    func showing() {
        OnboardingLaunch.markReached(.loginItem, store: flags)
        let model = makeModel()
        #expect(!model.isVisible)
        model.didShow()
        #expect(model.isVisible && model.step == .loginItem)
        model.didHide()
        #expect(!model.isVisible)
    }

    @Test("The welcome line and the pill follow the license status, and are absent without one")
    func licenseCopy() {
        let model = makeModel()
        #expect(model.licenseLine == nil && model.licenseBadge == nil)
        let source = StateBox(.trial(daysLeft: 2))
        license.bind(
            access: { source.state.isFeatureEnabled },
            state: { source.state },
            restriction: { LicenseRestriction.card(for: source.state) },
            badge: { LicenseBadge.label(for: source.state, appName: Licensing.appName) },
            canBuy: true
        )
        #expect(model.licenseLine == "Your free trial is running, with 2 days left. No signup needed. Buy a license any time in Settings → License.")
        #expect(model.licenseBadge?.text == "Free trial · 2 days left")
        source.state = .licensed
        #expect(model.licenseLine == "This Mac is licensed." && model.licenseBadge == nil)
        source.state = .trialEnded
        #expect(model.licenseLine?.hasPrefix("Your free trial has ended:") == true)
        #expect(model.licenseBadge?.tone == .attention)
    }

    @Test("The pill and the tips open License settings through the status")
    func openLicense() {
        var opened = 0
        license.openLicense = { opened += 1 }
        let temporary = try! TemporaryDefaults()
        let preferences = Preferences(defaults: temporary.defaults)
        let controller = OnboardingWindowController(
            loginItem: LoginItem(flags: flags, service: InertLoginItemService()), license: license, preferences: preferences,
            showSettings: {}, showAllNotes: {}, defaults: flags
        )
        controller.model.onOpenLicense?()
        #expect(opened == 1)
    }

    @Test("The model exposes the deck, hotkey and folder preferences the guide's files and tips steps read")
    func exposesPreferences() {
        let model = makeModel()
        #expect(model.preferences.side == .right)
        #expect(model.preferences.hotkey == .default)
        #expect(model.preferences.usesDefaultFolder)
    }
}

import ServiceManagement
