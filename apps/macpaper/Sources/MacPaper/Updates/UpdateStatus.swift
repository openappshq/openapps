import Foundation
import Observation

/// Compile-time facts about the updater in this build. Present in every
/// build so the rest of the app can ask without `#if`.
nonisolated enum Updating {
    #if OPENAPPS_OFFICIAL
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif

    /// The app id in the feed (`openapps:app`).
    static let appID = "macpaper"
    static let appName = "macPaper"
    /// How a Homebrew install updates too; Settings names it.
    static let upgradeCommand = "brew upgrade --cask macpaper"
}

/// What the panel's update row says about an update. Only the
/// states that ask something of the user, or tell them something is under
/// way; checking, up to date and a failed check stay in Settings → Updates.
nonisolated enum UpdateHint: Equatable {
    /// Found, not downloaded (automatic checks on, installing off): "Install".
    case available(version: String)
    /// Downloading after Install, or under "Download and install automatically".
    case downloading(version: String)
    /// Verified and staged; installs on quit or now: "Restart".
    case ready(version: String)

    var version: String {
        switch self {
        case .available(let version), .downloading(let version), .ready(let version): version
        }
    }
}

/// What the UI reads about updates, in every build (RELEASES.md, "In-app
/// updater"). An official build binds the updater's phase; the accessor
/// reads it afresh each time, so a view body that evaluates it observes the
/// updater itself. A build without the updater never binds anything: no
/// hint, ever. Nothing here reads the license or trial state.
@MainActor
@Observable
final class UpdateStatus {
    @ObservationIgnored private var currentHint: () -> UpdateHint? = { nil }
    /// "Install": download, verify and restart into the found update.
    @ObservationIgnored var install: () -> Void = {}
    /// "Restart": install the staged update through the quit path and reopen.
    @ObservationIgnored var restart: () -> Void = {}

    /// The update to mention, or nil.
    func hint() -> UpdateHint? {
        currentHint()
    }

    func bind(hint: @escaping () -> UpdateHint?, install: @escaping () -> Void, restart: @escaping () -> Void) {
        currentHint = hint
        self.install = install
        self.restart = restart
    }
}
