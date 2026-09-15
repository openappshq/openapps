#if OPENAPPS_OFFICIAL
import AppKit
import OpenAppsUpdater

/// OpenReaction's instance of the shared updater (RELEASES.md, "In-app
/// updater"): the feed and public key come from Info.plist, written by
/// scripts/bundle.sh. Builds from source compile none of this, and nothing
/// here reads the license or trial state.
@MainActor
enum Updates {
    static func make() -> Updater? {
        guard let configuration = UpdaterConfiguration(
            bundle: .main, appID: "openreaction", appName: "OpenReaction",
            allowsInsecureLoopback: UpdateTesting.isCompiledIn)
        else {
            // An official build always has both keys; without them there is no updater rather than a permissive one.
            return nil
        }
        let updater = Updater(configuration: configuration)
        updater.onStaged = { staged in UpdateTesting.updateIsReady(installNow: { updater.restartToUpdate() }, version: staged.item.version.description) }
        updater.onCheckFinished = { error in UpdateTesting.cycleFinished(error: error) }
        updater.onPhaseChange = { [weak updater] phase in
            guard let updater else { return }
            UpdateTesting.phaseChanged(phase, revoke: { updater.setInstallsAutomatically(false) })
        }
        return updater
    }
}

extension Updater {
    /// The version waiting to be installed, for the menu and Settings.
    var readyVersion: String? {
        if case .staged(let staged) = phase { return staged.item.version.description }
        return nil
    }
}
#endif
