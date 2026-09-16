import Foundation
import OpenAppsLicensing

/// Compile-time facts about licensing in this build. Present in every build
/// so the rest of the app can ask without `#if`.
nonisolated enum Licensing {
    #if OPENAPPS_LICENSING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif

    /// The app id the record store, the trial registry and the device hash use.
    static let appID = "hertz"
    /// The app as the License screen and the badge name it.
    static let appName = "Hertz"
    /// The preferences suite the invalidation journal lives in.
    static let journalSuite = "space.openapps.hertz.license"

    /// The trial's length. A debug build can shorten it to run the whole
    /// flow (start, "less than a day left", the offline limit, the end) in
    /// minutes: `HERTZ_DEBUG_TRIAL_DAY_SECONDS=60` makes a trial "day" one
    /// minute, so the trial lasts three. Release builds always use the real
    /// length; the override is not compiled into them.
    static var trialTiming: TrialTiming {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["HERTZ_DEBUG_TRIAL_DAY_SECONDS"]
            ?? UserDefaults.standard.string(forKey: "HertzDebugTrialDaySeconds"),
            let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 1 {
            return TrialTiming(day: seconds)
        }
        #endif
        return .standard
    }
}

/// Text shared by the License screen, About, the setup guide and the README
/// (LICENSING.md, "Privacy copy").
nonisolated enum LicensingCopy {
    static let privacy = "Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use Hertz are never sent. Builds from source never contact the license service."

    /// What Hertz reads and where it goes: the readings never leave the Mac.
    /// The licensed build adds the two calls above; a source build makes none.
    static var readings: String {
        Licensing.isCompiledIn
            ? "Every reading comes from this Mac’s kernel and stays here. The only network calls are the license check and the trial registry, described under License."
            : "Every reading comes from this Mac’s kernel and stays here. This build from source makes no network calls at all."
    }
}

/// What the UI reads about licensing, in every build: the readings are on
/// with nothing to say until an official build's `LicenseController` says
/// otherwise (`AppDelegate` copies its state here on every change). A build
/// with licensing compiled out never changes it.
@MainActor
@Observable
final class LicenseStatus {
    /// Whether the readings run (LICENSING.md: the core feature).
    private(set) var isFeatureEnabled = true
    /// The trial's remaining time or the short reason the readings are off;
    /// nil while simply licensed, or without licensing.
    private(set) var badge: LicenseBadge.Label?
    /// The dashboard's card while the readings are off.
    private(set) var restriction: LicenseRestriction?
    /// An activation, removal or check is running: the card's buttons wait.
    private(set) var isBusy = false
    /// The website has a page to buy on (`LicensingConfig.buyURL`).
    private(set) var canBuy = false

    /// Opens the website's Hertz page.
    @ObservationIgnored var buy: () -> Void = {}
    /// Opens Settings → License with the key field ready.
    @ObservationIgnored var enterKey: () -> Void = {}
    /// Opens Settings → License.
    @ObservationIgnored var openLicense: () -> Void = {}
    /// Retries storage, the registry or the check now.
    @ObservationIgnored var tryAgain: () -> Void = {}

    func update(isFeatureEnabled: Bool, badge: LicenseBadge.Label?, restriction: LicenseRestriction?, isBusy: Bool, canBuy: Bool) {
        if self.isFeatureEnabled != isFeatureEnabled { self.isFeatureEnabled = isFeatureEnabled }
        if self.badge != badge { self.badge = badge }
        if self.restriction != restriction { self.restriction = restriction }
        setBusy(isBusy)
        if self.canBuy != canBuy { self.canBuy = canBuy }
    }

    func setBusy(_ busy: Bool) {
        if isBusy != busy { isBusy = busy }
    }
}

/// What the license state does to Hertz's two surfaces (design/products/hertz.md,
/// "Licensing"). The core feature is the live readings: while it is off, the
/// menu-bar item shows the pulse alone and the dashboard shows this card
/// instead of the metric cards. Settings, License and Quit always work.
nonisolated struct LicenseRestriction: Equatable {
    enum Action: Equatable {
        /// Opens the website's Hertz page (`LicensingConfig.buyURL`).
        case buy
        /// Opens Settings → License with the key field ready.
        case enterKey
        /// Retries storage, the registry or the license check now.
        case tryAgain
    }

    /// The state in the words LICENSING.md gives it.
    let title: String
    /// What to do about it.
    let detail: String
    let actions: [Action]

    /// nil while the readings run (Trial, Licensed, Grace); a card otherwise.
    /// `storageError` and `trialStorageError` refine `trialUnavailable`, as
    /// for the badge.
    static func card(for state: LicenseState, storageError: Bool = false, trialStorageError: Bool = false) -> LicenseRestriction? {
        switch state {
        case .trial, .licensed, .grace:
            return nil
        case .trialUnavailable:
            if storageError {
                return LicenseRestriction(
                    title: "Can’t read the license record",
                    detail: "Hertz keeps retrying. Check that its Application Support folder is readable and writable; details are under Settings → License.",
                    actions: [.tryAgain, .enterKey]
                )
            }
            if trialStorageError {
                return LicenseRestriction(
                    title: "Can’t read or save the free trial record",
                    detail: "Hertz keeps retrying. Check that its Application Support folder is readable and writable; details are under Settings → License.",
                    actions: [.tryAgain, .enterKey]
                )
            }
            return LicenseRestriction(
                title: "Starting your free trial…",
                detail: "The readings appear as soon as the trial record is saved. No signup.",
                actions: [.enterKey]
            )
        case .trialEnded:
            return LicenseRestriction(
                title: "Your free trial has ended",
                detail: "Buy a license to keep the readings, or enter a key you already have. Settings and Quit keep working.",
                actions: [.buy, .enterKey]
            )
        case .trialNeedsConnection:
            return LicenseRestriction(
                title: "Connect to the internet to continue your free trial",
                detail: "The trial ran for a day without reaching the trial registry once. It picks up where it left off as soon as it does.",
                actions: [.tryAgain, .buy, .enterKey]
            )
        case .trialClockBehind:
            return LicenseRestriction(
                title: "Your Mac’s clock is behind",
                detail: "Set the correct date and time to keep using your free trial. No trial time is lost.",
                actions: [.buy, .enterKey]
            )
        case .checkRequired:
            return LicenseRestriction(
                title: "Connect to the internet to verify your license",
                detail: "The license hasn’t been checked for a week. One successful check turns the readings back on.",
                actions: [.tryAgain, .enterKey]
            )
        case .revoked:
            return LicenseRestriction(
                title: "This license is no longer active on this Mac",
                detail: "It was refunded, disabled, or this Mac was removed from it. Activate a key again, or buy a license.",
                actions: [.enterKey, .buy]
            )
        }
    }

    /// The menu-bar item's readout is part of the core feature: only the
    /// symbol while restricted.
    static func menuBarShowsReadout(for state: LicenseState) -> Bool {
        state.isFeatureEnabled
    }
}
