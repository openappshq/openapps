import Foundation
import Observation

/// Compile-time facts about licensing in this build. Present in every build
/// so the rest of the app can ask without `#if`. The licensing ticket
/// links `packages/openapps-licensing` behind `OPENAPPS_LICENSING`
/// (LICENSING.md, "Adding licensing to a new app"); until then every
/// build behaves as a source build: everything on, no trial, no License
/// section.
nonisolated enum Licensing {
    #if OPENAPPS_LICENSING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif

    /// The app id the record store, the trial registry and the device hash use.
    static let appID = "macpaper"
    /// The app as the License screen and the badge name it.
    static let appName = "macPaper"
    /// The preferences suite the invalidation journal lives in.
    static let journalSuite = "space.openapps.macpaper.license"

    /// The build's flavour, for Copy Diagnostics.
    static var flavourDescription: String {
        isCompiledIn ? "official build" : "compiled out (source build)"
    }
}

/// Text shared by Settings → About and the README (LICENSING.md, "Privacy copy").
nonisolated enum LicensingCopy {
    static let privacy = "Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your wallpapers, and how you use macPaper are never sent. Builds from source never contact the license service."

    /// What macPaper does with data: everything stays on the Mac. Each
    /// flavour names exactly the calls it can make.
    static var network: String {
        if Licensing.isCompiledIn {
            "Every wallpaper is made on this Mac and stays here: the documents, favorites and imported images live in Application Support, the renders in the folder you export to. The only network calls are the license check and the trial registry, described under License."
        } else {
            "Every wallpaper is made on this Mac and stays here: the documents, favorites and imported images live in Application Support, the renders in the folder you export to. This build from source makes no network calls at all."
        }
    }
}

/// What the license state does to macPaper's surfaces
/// (design/products/macpaper.md, "Licensing"). The core feature is
/// generating and applying: while restricted, the panel and the popover
/// show this card in place of the generator, and Shuffle, Apply and Export
/// are off. Settings, favorites and Quit always work. The licensing ticket
/// maps the package's states to cards; today nothing produces one.
nonisolated struct LicenseRestriction: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Opens the website's macPaper page.
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

    /// The card the preview harness shows, so the restricted layout can be
    /// seen before the licensing ticket lands.
    static let trialEndedSample = LicenseRestriction(
        title: "Your free trial has ended",
        detail: "Buy a license to keep making wallpapers, or enter a key you already have. The wallpaper you applied stays; Settings and Quit keep working.",
        actions: [.buy, .enterKey]
    )
}

/// What the UI reads about licensing, in every build. The entitlement is
/// never a stored flag here: `hasAccess` and `restriction` ask the bound
/// source each time, so a view body or an action evaluated after a
/// deadline sees the lapse even before any timer has fired. `revision` is
/// what a view observes; the controller bumps it on every published
/// change. A build with licensing compiled out never binds anything:
/// always on.
@Observable
final class LicenseStatus {
    private(set) var revision = 0
    private(set) var isBusy = false
    private(set) var canBuy = false

    @ObservationIgnored private var currentAccess: () -> Bool = { true }
    @ObservationIgnored private var currentRestriction: () -> LicenseRestriction? = { nil }

    /// Opens the website's macPaper page.
    @ObservationIgnored var buy: () -> Void = {}
    /// Opens Settings → License with the key field ready.
    @ObservationIgnored var enterKey: () -> Void = {}
    /// Retries storage, the registry or the check now.
    @ObservationIgnored var tryAgain: () -> Void = {}

    /// Whether generating and applying are allowed right now.
    func hasAccess() -> Bool {
        _ = revision
        return currentAccess()
    }

    /// The card while restricted; nil while the feature runs.
    func restriction() -> LicenseRestriction? {
        _ = revision
        return currentRestriction()
    }

    /// Binds the live source. Every accessor calls these closures afresh.
    func bind(access: @escaping () -> Bool, restriction: @escaping () -> LicenseRestriction?, canBuy: Bool) {
        currentAccess = access
        currentRestriction = restriction
        self.canBuy = canBuy
        publish()
    }

    /// The source changed: observers re-read through the closures.
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
