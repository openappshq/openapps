#if OPENAPPS_OFFICIAL
import AppKit
import OpenNotesCore
import OpenAppsUpdater

/// OpenNotes's instance of the shared updater (RELEASES.md, "In-app updater"):
/// the feed and public key come from Info.plist, written by
/// scripts/bundle.sh. Builds from source compile none of this, and nothing
/// here reads the license or trial state.
///
/// "Check for updates automatically" is on by default, but only on a
/// demonstrably fresh install, by the same rule and flag as "Open at login"
/// (`FreshInstallDefault`): decided once, when storage says whether the
/// install is fresh, and never for an upgrade. The Settings toggle goes
/// through `setChecksAutomatically(_:)`, which records the user's choice
/// before the switch, so a default still pending can never undo it.
/// "Download and install automatically" has no default of its own: it stays
/// off until the user turns it on.
@MainActor
final class Updates {
    let updater: Updater
    /// Created at launch, before this launch writes any preferences.
    private let checkDefault: FreshInstallDefault

    static func make(flags: any FlagStore = UserDefaults.standard) -> Updates? {
        guard let configuration = UpdaterConfiguration(
            bundle: .main, appID: Updating.appID, appName: Updating.appName,
            allowsInsecureLoopback: UpdateTesting.isCompiledIn)
        else {
            // An official build always has both keys; without them there is no updater rather than a permissive one.
            return nil
        }
        let updater = Updater(configuration: configuration)
        updater.onStaged = { staged in UpdateTesting.updateIsReady(installNow: { updater.restartToUpdate() }, version: staged.item.version.description) }
        updater.onCheckFinished = { error in UpdateTesting.cycleFinished(error: error) }
        updater.onQuitFinished = { outcome, reopening in UpdateTesting.quitFinished(outcome: "\(outcome)", reopening: reopening) }
        updater.onPhaseChange = { [weak updater] phase in
            guard let updater else { return }
            UpdateTesting.phaseChanged(phase, revoke: { updater.setInstallsAutomatically(false) })
        }
        return Updates(updater: updater, flags: flags)
    }

    init(updater: Updater, flags: any FlagStore = UserDefaults.standard) {
        self.updater = updater
        checkDefault = .updateChecks(store: flags)
    }

    /// The user's choice in Settings. Recorded first, so the default can
    /// never undo it — also when storage has not answered yet and the
    /// default is still pending. Turning it off still cancels the automatic
    /// work in flight, as before.
    func setChecksAutomatically(_ on: Bool) {
        checkDefault.markSuperseded()
        updater.setChecksAutomatically(on)
    }

    /// The default, once: turns automatic checks on when the install is
    /// demonstrably fresh (no earlier preferences, and `storageIsFresh` — the
    /// license and trial records positively absent; nil while unknown, which
    /// waits). Once decided, nothing is asked again. Turning the toggle on
    /// starts the updater's own schedule: a check now if one is due, then
    /// every 24 hours and on wake.
    func applyCheckDefaultIfNeeded(storageIsFresh: Bool?) {
        guard storageIsFresh != nil, !checkDefault.isDecided else { return }
        guard checkDefault.shouldTurnOn(isOn: updater.checksAutomatically, storageIsFresh: storageIsFresh) else { return }
        updater.setChecksAutomatically(true)
    }

    /// Binds what All Notes' footer and the status menu read. The hint closure reads
    /// the updater's phase afresh, so a view that evaluates it observes it.
    func bind(_ status: UpdateStatus) {
        let updater = self.updater
        status.bind(
            hint: { UpdateHint(phase: updater.phase) },
            install: { updater.installAvailable() },
            restart: { updater.restartToUpdate() }
        )
    }
}

extension UpdateHint {
    /// What the update row says about a phase: nothing while idle, checking, up
    /// to date or failed (Settings → Updates carries those).
    init?(phase: Updater.Phase) {
        switch phase {
        case .available(let item): self = .available(version: item.version.description)
        case .downloading(let item): self = .downloading(version: item.version.description)
        case .staged(let staged): self = .ready(version: staged.item.version.description)
        case .idle, .checking, .upToDate, .failed: return nil
        }
    }
}
#endif
