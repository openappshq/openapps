import Foundation
import Observation
import OpenAppsLicensing

/// Compile-time facts about licensing in this build. Present in every build
/// so the rest of the app can ask without `#if`. An official build links
/// `packages/openapps-licensing` behind `OPENAPPS_LICENSING` (LICENSING.md,
/// "Adding licensing to a new app"); a build from source behaves as every
/// source build does: everything on, no trial, no License section.
nonisolated enum Licensing {
    #if OPENAPPS_LICENSING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif

    /// The app id the record store, the trial registry and the device hash use.
    static let appID = "opennotes"
    /// The app as the License screen and the badge name it.
    static let appName = "OpenNotes"
    /// The preferences suite the invalidation journal lives in.
    static let journalSuite = "space.openapps.opennotes.license"

    /// The build's flavour, for Copy Diagnostics.
    static var flavourDescription: String {
        isCompiledIn ? "official build" : "off (source build: no trial, no license network calls)"
    }

    /// The flavour and, in an official build, where the license stands as
    /// of this moment (the badge's words, or "licensed"), for Copy
    /// Diagnostics. Never the key.
    @MainActor
    static func diagnosticsLine(_ status: LicenseStatus) -> String {
        guard let state = status.state() else { return flavourDescription }
        let standing = status.badge()?.text ?? (state.isFeatureEnabled ? "licensed" : "off")
        return "\(flavourDescription) · \(standing)"
    }

    /// The trial's length. A debug build can shorten it to run the whole
    /// flow (start, "less than a day left", the offline limit, the end) in
    /// minutes: `OPENNOTES_DEBUG_TRIAL_DAY_SECONDS=60` makes a trial "day"
    /// one minute, so the trial lasts three. Release builds always use the
    /// real length; the override is not compiled into them.
    static var trialTiming: TrialTiming {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["OPENNOTES_DEBUG_TRIAL_DAY_SECONDS"]
            ?? UserDefaults.standard.string(forKey: "OpenNotesDebugTrialDaySeconds"),
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
    static let privacy = "Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your notes, and how you use OpenNotes are never sent. Builds from source never contact the license service."

    /// What OpenNotes does with data: everything stays on the Mac. Each
    /// flavour names exactly the calls it can make: the license check and
    /// the trial registry with licensing, the update check (a plain GET of
    /// the signed feed, RELEASES.md) with the updater, none from source.
    static var network: String {
        let stays = "OpenNotes reads and writes your notes only in the folder you chose — every note is a plain file there — and uploads nothing; its settings, and in official builds its license and update records, stay under Library."
        switch (Licensing.isCompiledIn, Updating.isCompiledIn) {
        case (true, true):
            return stays + " The only network calls are the license check and the trial registry, described under License, and the update check, described under Updates."
        case (true, false):
            return stays + " The only network calls are the license check and the trial registry, described under License."
        case (false, true):
            return stays + " The only network call is the update check, described under Updates."
        case (false, false):
            return stays + " This build from source makes no network calls at all."
        }
    }
}

/// What the setup guide says about the license: only what the state
/// reports now, never a claim it does not back (a kept ended trial, a
/// failed first save, a paid license). Nothing without licensing.
nonisolated enum GuideCopy {
    static func licenseLine(state: LicenseState?) -> String? {
        guard let state else { return nil }
        switch state {
        case .trial(let days):
            let left = days <= 1 ? "less than a day left" : "\(days) days left"
            return "Your free trial is running, with \(left). No signup needed. Buy a license any time in Settings → License."
        case .trialEnded:
            return "Your free trial has ended: your notes are read-only until this Mac is licensed. Settings → License is where to buy a license or paste a key."
        case .licensed, .grace:
            return "This Mac is licensed."
        case .trialUnavailable, .trialNeedsConnection, .trialClockBehind, .checkRequired, .revoked:
            return "Official builds include a free 3-day trial. Settings → License shows where it stands."
        }
    }
}

/// What the license state does to OpenNotes' surfaces
/// (design/products/opennotes.md, "Licensing"). The core feature is
/// writing notes: while restricted the app is **read-only** — the deck
/// stays visible and every note stays readable, searchable and exportable;
/// creating a note, editing text, renaming, archiving, unarchiving,
/// reordering, deleting an archived note and changing the notes folder
/// are refused with this card (in All Notes) or its `notice` (the open
/// note's footer). Settings, Export, Reveal in Finder and Quit always
/// work; nothing the user wrote is hidden or changed.
nonisolated struct LicenseRestriction: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Opens the website's OpenNotes page (`LicensingConfig.buyURL`).
        case buy
        /// Opens Settings → License with the key field ready.
        case enterKey
        /// Retries storage, the registry or the license check now.
        case tryAgain

        var title: String {
            switch self {
            case .buy: "Buy a license"
            case .enterKey: "Enter a key"
            case .tryAgain: "Try again"
            }
        }
    }

    /// The state in the words LICENSING.md gives it.
    let title: String
    /// What to do about it.
    let detail: String
    let actions: [Action]

    /// The one line the open note's footer and the status menu show while
    /// read-only: the title, and that the notes are read-only.
    var notice: String {
        let reason = title.prefix(1).lowercased() + title.dropFirst()
        return "Read-only: \(reason)\(reason.hasSuffix("…") ? "" : ".") Your notes stay readable; Settings → License."
    }

    /// nil while the feature runs (Trial, Licensed, Grace); a card otherwise.
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
                    detail: "Your notes are read-only until it can be read. OpenNotes keeps retrying; check that its Application Support folder is readable and writable. Details are under Settings → License.",
                    actions: [.tryAgain, .enterKey]
                )
            }
            if trialStorageError {
                return LicenseRestriction(
                    title: "Can’t read or save the free trial record",
                    detail: "Your notes are read-only until it can be read. OpenNotes keeps retrying; check that its Application Support folder is readable and writable. Details are under Settings → License.",
                    actions: [.tryAgain, .enterKey]
                )
            }
            return LicenseRestriction(
                title: "Starting your free trial…",
                detail: "Writing notes begins as soon as the trial record is saved. No signup.",
                actions: [.enterKey]
            )
        case .trialEnded:
            return LicenseRestriction(
                title: "Your free trial has ended",
                detail: "Your notes are read-only: every note stays where it is, readable, searchable and exportable, and nothing is changed. Buy a license to keep writing, or enter a key you already have.",
                actions: [.buy, .enterKey]
            )
        case .trialNeedsConnection:
            return LicenseRestriction(
                title: "Connect to the internet to continue your free trial",
                detail: "The trial ran for a day without reaching the trial registry once; your notes are read-only until it does, and it picks up where it left off.",
                actions: [.tryAgain, .buy, .enterKey]
            )
        case .trialClockBehind:
            return LicenseRestriction(
                title: "Your Mac’s clock is behind",
                detail: "Set the correct date and time to keep writing notes. No trial time is lost; your notes are read-only meanwhile.",
                actions: [.buy, .enterKey]
            )
        case .checkRequired:
            return LicenseRestriction(
                title: "Connect to the internet to verify your license",
                detail: "The license hasn’t been checked for a week. One successful check turns writing back on; your notes are read-only meanwhile.",
                actions: [.tryAgain, .enterKey]
            )
        case .revoked:
            return LicenseRestriction(
                title: "This license is no longer active on this Mac",
                detail: "It was refunded, disabled, or this Mac was removed from it. Your notes are read-only; activate a key again, or buy a license.",
                actions: [.enterKey, .buy]
            )
        }
    }

    /// The card the preview harness shows, so the read-only layout can be
    /// seen without a license state.
    static let trialEndedSample = card(for: .trialEnded)!
}

/// What the UI reads about licensing, in every build. The entitlement is
/// never a stored flag here: `hasAccess`, `restriction` and `badge` ask the
/// bound source each time — in an official build the license controller's
/// projection of the manager's latest snapshot to the current clocks — so a
/// view body or an action evaluated after a deadline sees the lapse even
/// before any timer has fired. `revision` is what a view observes; the
/// controller bumps it on every published change so SwiftUI re-reads. A
/// build with licensing compiled out never binds anything: always on. A
/// build with licensing starts **restricted** — the state the controller
/// itself projects until storage has answered — so nothing the launch
/// path runs before the binding (the auto-archive sweep, a flush) can
/// write on a status nobody has bound yet.
@Observable
final class LicenseStatus {
    /// Bumped whenever the source published a change; read by the accessors
    /// so observers re-evaluate them.
    private(set) var revision = 0
    /// An activation, removal or check is running: the card's buttons wait.
    private(set) var isBusy = false
    /// The website has a page to buy on (`LicensingConfig.buyURL`).
    private(set) var canBuy = false

    @ObservationIgnored private var currentAccess: () -> Bool
    @ObservationIgnored private var currentState: () -> LicenseState?
    @ObservationIgnored private var currentRestriction: () -> LicenseRestriction?
    @ObservationIgnored private var currentBadge: () -> LicenseBadge.Label?

    /// `startsRestricted` is the flavour's default: a build with licensing
    /// answers "starting your free trial…" (no access) until bound; a build
    /// without answers yes and says nothing. A test that stands in for the
    /// source flavour passes `false` explicitly.
    init(startsRestricted: Bool = Licensing.isCompiledIn) {
        currentAccess = { !startsRestricted }
        currentState = { startsRestricted ? .trialUnavailable : nil }
        currentRestriction = { startsRestricted ? LicenseRestriction.card(for: .trialUnavailable) : nil }
        currentBadge = { startsRestricted ? LicenseBadge.label(for: .trialUnavailable, appName: Licensing.appName) : nil }
    }

    /// Opens the website's OpenNotes page.
    @ObservationIgnored var buy: () -> Void = {}
    /// Opens Settings → License with the key field ready.
    @ObservationIgnored var enterKey: () -> Void = {}
    /// Opens Settings → License.
    @ObservationIgnored var openLicense: () -> Void = {}
    /// Retries storage, the registry or the check now.
    @ObservationIgnored var tryAgain: () -> Void = {}

    /// Whether writing notes is allowed right now.
    func hasAccess() -> Bool {
        _ = revision
        return currentAccess()
    }

    /// The projected state, for copy that names it (the guide); nil without
    /// licensing.
    func state() -> LicenseState? {
        _ = revision
        return currentState()
    }

    /// The card while read-only; nil while writing is allowed.
    func restriction() -> LicenseRestriction? {
        _ = revision
        return currentRestriction()
    }

    /// The trial's remaining time or the short reason the app is read-only;
    /// nil while simply licensed, or without licensing.
    func badge() -> LicenseBadge.Label? {
        _ = revision
        return currentBadge()
    }

    /// Binds the live source. Every accessor calls these closures afresh.
    func bind(
        access: @escaping () -> Bool,
        state: @escaping () -> LicenseState?,
        restriction: @escaping () -> LicenseRestriction?,
        badge: @escaping () -> LicenseBadge.Label?,
        canBuy: Bool
    ) {
        currentAccess = access
        currentState = state
        currentRestriction = restriction
        currentBadge = badge
        self.canBuy = canBuy
        publish()
    }

    /// A source with no state or badge of its own (the preview harness's
    /// sample card, a test that moves access by hand).
    func bind(access: @escaping () -> Bool, restriction: @escaping () -> LicenseRestriction?, canBuy: Bool) {
        bind(access: access, state: { nil }, restriction: restriction, badge: { nil }, canBuy: canBuy)
    }

    /// The source changed (a new snapshot, a deadline, a wake): observers
    /// re-read through the closures.
    func publish() {
        revision &+= 1
    }

    func setBusy(_ busy: Bool) {
        if isBusy != busy { isBusy = busy }
    }

    func perform(_ action: LicenseRestriction.Action) {
        switch action {
        case .buy: buy()
        case .enterKey: enterKey()
        case .tryAgain: tryAgain()
        }
    }
}
