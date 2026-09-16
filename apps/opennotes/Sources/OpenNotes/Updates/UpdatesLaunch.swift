import AppKit

/// The launch path's updater half (RELEASES.md, "In-app updater"): only an
/// official build has one. Independent of licensing: updates never depend
/// on the license or trial state.
extension AppDelegate {
    /// Creates the updater and binds what the app reads. Called before
    /// this launch writes any preferences, so its fresh-install default
    /// reads the launch's. Nothing is checked yet.
    func startUpdates() {
        #if OPENAPPS_OFFICIAL
        let updates = Updates.make()
        self.updates = updates
        updates?.bind(model.updates)
        #endif
    }

    /// Recovers an interrupted swap; checks only if the toggle is on and a
    /// check is due.
    func startUpdaterSchedule() {
        #if OPENAPPS_OFFICIAL
        updates?.updater.start()
        #endif
    }
}
