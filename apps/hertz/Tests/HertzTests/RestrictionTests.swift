import Foundation
@testable import Hertz
import OpenAppsLicensing
import Testing

/// Every license state, so a new case in the package cannot slip past the
/// mapping unnoticed.
let everyState: [LicenseState] = [
    .trialUnavailable, .trial(daysLeft: 3), .trial(daysLeft: 1), .trialNeedsConnection, .trialClockBehind, .trialEnded,
    .licensed, .grace(daysLeft: 5, showWarning: false), .grace(daysLeft: 2, showWarning: true), .checkRequired, .revoked,
]

/// State → what Hertz shows: the readout and the metric cards while the
/// core feature is on, the pulse alone and one card while it is off
/// (design/products/hertz.md, "Licensing").
@Suite("License restriction")
struct RestrictionTests {
    @Test("The menu bar and the dashboard follow the core feature together", arguments: everyState)
    func surfacesFollowTheFeature(state: LicenseState) {
        let card = LicenseRestriction.card(for: state)
        #expect(LicenseRestriction.menuBarShowsReadout(for: state) == state.isFeatureEnabled)
        #expect((card == nil) == state.isFeatureEnabled)
    }

    @Test("Every restricted state offers a way out, and never a price", arguments: everyState.filter { !$0.isFeatureEnabled })
    func restrictedStatesOfferAWayOut(state: LicenseState) throws {
        let card = try #require(LicenseRestriction.card(for: state))
        #expect(!card.actions.isEmpty)
        #expect(!card.title.isEmpty && !card.detail.isEmpty)
        for text in [card.title, card.detail] {
            #expect(!text.contains("$"), "the website states the price, the app never does")
        }
    }

    @Test("The trial's end says so and sells, with a place for a key")
    func trialEnded() throws {
        let card = try #require(LicenseRestriction.card(for: .trialEnded))
        #expect(card.title == "Your free trial has ended")
        #expect(card.actions == [.buy, .enterKey])
    }

    @Test("A licensed Mac that must check is asked to connect, not to buy")
    func checkRequired() throws {
        let card = try #require(LicenseRestriction.card(for: .checkRequired))
        #expect(card.title == "Connect to the internet to verify your license")
        #expect(card.actions.contains(.tryAgain))
        #expect(!card.actions.contains(.buy))
    }

    @Test("A revoked license activates again first")
    func revoked() throws {
        let card = try #require(LicenseRestriction.card(for: .revoked))
        #expect(card.actions.first == .enterKey)
        #expect(card.actions.contains(.buy))
    }

    @Test("Clock behind and the offline limit name the fix, as LICENSING.md words it")
    func trialProblems() throws {
        #expect(try #require(LicenseRestriction.card(for: .trialClockBehind)).title == "Your Mac’s clock is behind")
        let offline = try #require(LicenseRestriction.card(for: .trialNeedsConnection))
        #expect(offline.title == "Connect to the internet to continue your free trial")
        #expect(offline.actions.first == .tryAgain)
    }

    @Test("Storage errors refine the unavailable trial and offer a retry")
    func storageErrors() throws {
        let starting = try #require(LicenseRestriction.card(for: .trialUnavailable))
        #expect(starting.title == "Starting your free trial…")
        #expect(!starting.actions.contains(.tryAgain))
        let license = try #require(LicenseRestriction.card(for: .trialUnavailable, storageError: true))
        #expect(license.title == "Can’t read the license record")
        #expect(license.actions.first == .tryAgain)
        let trial = try #require(LicenseRestriction.card(for: .trialUnavailable, trialStorageError: true))
        #expect(trial.title == "Can’t read or save the free trial record")
        #expect(trial.actions.first == .tryAgain)
    }
}

/// The pill's text comes from the package, with Hertz's name where the copy
/// needs it; it is absent exactly while licensed.
@Suite("License badge")
struct BadgeTests {
    @Test("Licensed and quiet grace show nothing; every other state a label", arguments: everyState)
    func presence(state: LicenseState) {
        let label = LicenseBadge.label(for: state, appName: Licensing.appName)
        switch state {
        case .licensed, .grace(_, showWarning: false): #expect(label == nil)
        default: #expect(label != nil)
        }
    }

    @Test func trialDaysAndTone() {
        #expect(LicenseBadge.label(for: .trial(daysLeft: 3), appName: Licensing.appName) == .init(text: "Free trial · 3 days left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 1), appName: Licensing.appName)?.text == "Free trial · less than a day left")
        #expect(LicenseBadge.label(for: .trialEnded, appName: Licensing.appName) == .init(text: "Trial ended", tone: .attention))
    }

    @Test func graceWarningNamesHertz() {
        let label = LicenseBadge.label(for: .grace(daysLeft: 2, showWarning: true), appName: Licensing.appName)
        #expect(label?.text == "Connect to the internet within 2 days to keep using Hertz")
        #expect(label?.tone == .attention)
    }

    @Test func storageErrorsRefineTheStartingLabel() {
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: Licensing.appName)?.text == "Starting your free trial…")
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: Licensing.appName, storageError: true)?.text == "Can’t read the license record")
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: Licensing.appName, trialStorageError: true)?.text == "Can’t read or save the free trial record")
    }

    @Test("The app's values are the ones every record, hash and suite are keyed by")
    func appValues() {
        #expect(Licensing.appID == "hertz")
        #expect(Licensing.appName == "Hertz")
        #expect(Licensing.journalSuite == "space.openapps.hertz.license")
        #expect(LicensingCopy.privacy.contains("how you use Hertz are never sent"))
        #expect(LicensingCopy.privacy.contains("Builds from source never contact the license service"))
    }
}

/// `LicenseStatus` is what the views read in every build: on with nothing
/// to say until an official build's controller says otherwise.
@Suite("License status")
@MainActor
struct LicenseStatusTests {
    @Test func startsOnWithNothingToSay() {
        let status = LicenseStatus()
        #expect(status.isFeatureEnabled)
        #expect(status.badge == nil)
        #expect(status.restriction == nil)
        #expect(!status.canBuy)
    }

    @Test func copiesTheControllersState() {
        let status = LicenseStatus()
        let card = LicenseRestriction.card(for: .trialEnded)
        status.update(isFeatureEnabled: false, badge: LicenseBadge.label(for: .trialEnded, appName: "Hertz"), restriction: card, isBusy: false, canBuy: true)
        #expect(!status.isFeatureEnabled)
        #expect(status.badge?.text == "Trial ended")
        #expect(status.restriction == card)
        #expect(status.canBuy)
        status.setBusy(true)
        #expect(status.isBusy)
    }
}
