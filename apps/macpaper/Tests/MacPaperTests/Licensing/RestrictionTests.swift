import Foundation
@testable import MacPaper
import MacPaperCore
import OpenAppsLicensing
import Testing

/// Every license state, so a new case in the package cannot slip past the
/// mapping unnoticed.
let everyState: [LicenseState] = [
    .trialUnavailable, .trial(daysLeft: 3), .trial(daysLeft: 1), .trialNeedsConnection, .trialClockBehind, .trialEnded,
    .licensed, .grace(daysLeft: 5, showWarning: false), .grace(daysLeft: 2, showWarning: true), .checkRequired, .revoked,
]

/// State → what macPaper shows: the generator and the actions while the
/// core feature is on, one card in their place while it is off
/// (design/products/macpaper.md, "Licensing").
@Suite("License restriction")
struct RestrictionTests {
    @Test("The card is there exactly while the feature is off", arguments: everyState)
    func cardFollowsTheFeature(state: LicenseState) {
        #expect((LicenseRestriction.card(for: state) == nil) == state.isFeatureEnabled)
    }

    @Test("Every restricted state offers a way out, and never a price", arguments: everyState.filter { !$0.isFeatureEnabled })
    func restrictedStatesOfferAWayOut(state: LicenseState) throws {
        let card = try #require(LicenseRestriction.card(for: state))
        #expect(!card.actions.isEmpty)
        #expect(!card.title.isEmpty && !card.detail.isEmpty)
        for text in [card.title, card.detail] {
            #expect(!text.contains("$"), "the website states the price, the app never does")
        }
        for action in card.actions {
            #expect(!action.title.contains("$"))
        }
    }

    @Test("The trial's end says so and sells, with a place for a key, and keeps the wallpaper")
    func trialEnded() throws {
        let card = try #require(LicenseRestriction.card(for: .trialEnded))
        #expect(card.title == "Your free trial has ended")
        #expect(card.actions == [.buy, .enterKey])
        #expect(card.detail.contains("The wallpaper you applied stays"))
        #expect(LicenseRestriction.trialEndedSample == card)
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

    @Test("The actions' titles are the buttons' words")
    func actionTitles() {
        #expect(LicenseRestriction.Action.buy.title == "Buy a license")
        #expect(LicenseRestriction.Action.enterKey.title == "Enter a key")
        #expect(LicenseRestriction.Action.tryAgain.title == "Try again")
    }
}

/// The pill's text comes from the package, with macPaper's name where the
/// copy needs it; it is absent exactly while licensed.
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

    @Test func graceWarningNamesMacPaper() {
        let label = LicenseBadge.label(for: .grace(daysLeft: 2, showWarning: true), appName: Licensing.appName)
        #expect(label?.text == "Connect to the internet within 2 days to keep using macPaper")
        #expect(label?.tone == .attention)
    }

    @Test("The app's values are the ones every record, hash and suite are keyed by")
    func appValues() {
        #expect(Licensing.appID == "macpaper")
        #expect(Licensing.appName == "macPaper")
        #expect(Licensing.journalSuite == "space.openapps.macpaper.license")
        #expect(Updating.appID == "macpaper")
        #expect(Updating.upgradeCommand == "brew upgrade --cask macpaper")
        #expect(LicensingCopy.privacy.contains("how you use macPaper are never sent"))
        #expect(LicensingCopy.privacy.contains("Builds from source never contact the license service"))
        #expect(!LicensingCopy.privacy.contains("$"))
    }

    @Test("The About copy names exactly the calls this flavour can make")
    func networkCopy() {
        let text = LicensingCopy.network
        #expect(text.hasPrefix("Every wallpaper is made on this Mac and stays here"))
        #expect(text.contains("license check") == Licensing.isCompiledIn)
        #expect(text.contains("update check") == Updating.isCompiledIn)
        #expect(text.contains("no network calls at all") == (!Licensing.isCompiledIn && !Updating.isCompiledIn))
    }
}

/// `LicenseStatus` is what the views read in every build: on with nothing
/// to say until bound to a live source, and never a stored answer after.
@Suite("License status")
@MainActor
struct LicenseStatusTests {
    @Test func startsOnWithNothingToSay() {
        let status = LicenseStatus()
        #expect(status.hasAccess())
        #expect(status.state() == nil)
        #expect(status.badge() == nil)
        #expect(status.restriction() == nil)
        #expect(!status.canBuy)
    }

    @Test("Every accessor asks the bound source afresh; nothing is cached between calls")
    func readsTheSourceLive() {
        let status = LicenseStatus()
        let source = StateBox(.trial(daysLeft: 3))
        status.bind(
            access: { source.state.isFeatureEnabled },
            state: { source.state },
            restriction: { LicenseRestriction.card(for: source.state) },
            badge: { LicenseBadge.label(for: source.state, appName: Licensing.appName) },
            canBuy: true
        )
        #expect(status.hasAccess())
        #expect(status.restriction() == nil)
        #expect(status.badge()?.text == "Free trial · 3 days left")
        // The source moves on without anyone calling `publish`: the next
        // read already sees it.
        source.state = .trialEnded
        #expect(!status.hasAccess())
        #expect(status.restriction()?.title == "Your free trial has ended")
        #expect(status.badge()?.text == "Trial ended")
        #expect(status.canBuy)
        status.setBusy(true)
        #expect(status.isBusy)
    }

    @Test("The card's actions reach the bound closures")
    func actionsReachTheirClosures() {
        let status = LicenseStatus()
        var performed: [String] = []
        status.buy = { performed.append("buy") }
        status.enterKey = { performed.append("enterKey") }
        status.tryAgain = { performed.append("tryAgain") }
        status.openLicense = { performed.append("openLicense") }
        status.perform(.buy)
        status.perform(.enterKey)
        status.perform(.tryAgain)
        status.openLicense()
        #expect(performed == ["buy", "enterKey", "tryAgain", "openLicense"])
    }

    @Test func publishBumpsTheRevisionObserversRead() {
        let status = LicenseStatus()
        let before = status.revision
        status.publish()
        #expect(status.revision == before + 1)
    }
}

/// The guide's welcome line says only what the state backs.
@Suite("Guide license line")
struct GuideCopyTests {
    @Test func nothingWithoutAState() {
        #expect(GuideCopy.licenseLine(state: nil) == nil)
    }

    @Test func followsTheState() {
        #expect(GuideCopy.licenseLine(state: .trial(daysLeft: 3)) == "Your free trial is running, with 3 days left. No signup needed. Buy a license any time in Settings → License.")
        #expect(GuideCopy.licenseLine(state: .trial(daysLeft: 1))?.contains("less than a day left") == true)
        #expect(GuideCopy.licenseLine(state: .trialEnded)?.hasPrefix("Your free trial has ended.") == true)
        #expect(GuideCopy.licenseLine(state: .licensed) == "This Mac is licensed.")
        #expect(GuideCopy.licenseLine(state: .grace(daysLeft: 2, showWarning: true)) == "This Mac is licensed.")
        for state in [LicenseState.trialUnavailable, .trialClockBehind, .trialNeedsConnection, .checkRequired, .revoked] {
            #expect(GuideCopy.licenseLine(state: state)?.contains("started") != true, "\(state) never claims a trial started")
            #expect(GuideCopy.licenseLine(state: state)?.contains("Settings → License") == true)
        }
    }
}

/// `macpaper://activate?key=…` pre-fills a key; every other link is left alone.
@Suite("Activate deep link")
struct ActivateLinkTests {
    @Test func readsTheKey() {
        #expect(ActivateLink.key(from: URL(string: "macpaper://activate?key=ABC-123")!) == "ABC-123")
        #expect(ActivateLink.key(from: URL(string: "MACPAPER://Activate?key=%20ABC%0A")!) == "ABC", "trimmed, case-insensitive")
    }

    @Test func ignoresEverythingElse() {
        for link in ["macpaper://activate", "macpaper://activate?key=", "macpaper://activate?key=%20", "macpaper://share?code=ABC", "hertz://activate?key=ABC", "https://openapps.space/macpaper/?key=ABC"] {
            #expect(ActivateLink.key(from: URL(string: link)!) == nil, Comment(rawValue: link))
        }
    }
}
