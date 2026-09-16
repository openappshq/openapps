import Foundation

/// The few flags the app keeps between launches for first-run decisions.
/// `UserDefaults` conforms as is; tests use a dictionary.
public protocol FlagStore {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: FlagStore {}

/// When the setup window opens on its own: once, on the first launch; after
/// a relaunch the window itself started; and after macOS quit and reopened
/// the app while the window was waiting on a permission it had just asked
/// for (granting Accessibility or Input Monitoring in System Settings ends
/// with "Quit & Reopen", a relaunch the app did not start). Afterwards it
/// is reached from Settings ("Show setup guide"), the status menu, or by
/// opening the app again while setup is incomplete; a window the user
/// closed never opens by itself again.
public enum OnboardingLaunch {
    public enum Key {
        public static let shown = "onboarding.shown"
        public static let resumeAfterRelaunch = "onboarding.resumeAfterRelaunch"
        /// The window asked for a permission and has not been closed since:
        /// a launch meanwhile is macOS reopening the app.
        public static let awaitingPermission = "onboarding.awaitingPermission"
    }

    /// Consumes both markers.
    public static func shouldShow(store: any FlagStore) -> Bool {
        let resume = store.bool(forKey: Key.resumeAfterRelaunch) || store.bool(forKey: Key.awaitingPermission)
        store.removeObject(forKey: Key.resumeAfterRelaunch)
        store.removeObject(forKey: Key.awaitingPermission)
        return resume || !store.bool(forKey: Key.shown)
    }

    /// The window was shown (by anyone): it no longer opens on launch.
    public static func markShown(store: any FlagStore) {
        store.set(true, forKey: Key.shown)
    }

    /// Call right before a relaunch started from the window, so the new
    /// process opens it again.
    public static func markResumeAfterRelaunch(store: any FlagStore) {
        store.set(true, forKey: Key.resumeAfterRelaunch)
    }

    /// Call when the window asks for a permission, so a launch before the
    /// window is closed opens it again.
    public static func markAwaitingPermission(store: any FlagStore) {
        store.set(true, forKey: Key.awaitingPermission)
    }

    /// Call when the user closes the window (skip, finish, the close
    /// button): an unfinished setup they dismissed stays dismissed.
    public static func clearAwaitingPermission(store: any FlagStore) {
        store.removeObject(forKey: Key.awaitingPermission)
    }
}

/// A setting official builds turn on once, on a demonstrably fresh install:
/// no preferences from an earlier launch (of any version), and neither a
/// trial nor a license record in the record store, both positively absent.
/// Anything else — an upgrade, a reinstall over kept records, a setting the
/// user once turned off — is left alone. Decided once; the flag makes every
/// later launch leave the setting as is. Two settings follow this rule
/// (RELEASES.md, "In-app updater"): "Open at login" and "Check for updates
/// automatically".
public struct FreshInstallDefault {
    public enum Key {
        /// The login-item default was applied (or found unnecessary); never again.
        public static let loginItemApplied = "loginItem.defaultApplied"
        /// The automatic-update-check default was applied (or found unnecessary); never again.
        public static let updateChecksApplied = "updates.checkDefaultApplied"
    }

    /// "Open at login".
    public static func loginItem(store: any FlagStore) -> FreshInstallDefault {
        FreshInstallDefault(store: store, key: Key.loginItemApplied)
    }

    /// "Check for updates automatically".
    public static func updateChecks(store: any FlagStore) -> FreshInstallDefault {
        FreshInstallDefault(store: store, key: Key.updateChecksApplied)
    }

    private let store: any FlagStore
    /// The flag under which the decision is recorded.
    public let key: String
    /// An earlier launch left preferences behind. Read when this is created,
    /// at launch, before the current launch writes any.
    public let hadPreferences: Bool

    public init(store: any FlagStore, key: String) {
        self.store = store
        self.key = key
        hadPreferences = store.bool(forKey: OnboardingLaunch.Key.shown)
    }

    /// The default was applied, found unnecessary, or superseded by the
    /// user: nothing is left to decide, and the setting need not be read.
    public var isDecided: Bool { store.bool(forKey: key) }

    /// The user switched the setting themselves. Recorded before the switch
    /// takes effect, and also while storage has not answered yet, so the
    /// default can never undo an explicit choice.
    public func markSuperseded() {
        store.set(true, forKey: key)
    }

    /// Whether to turn the setting on now. `isOn` is its current value;
    /// `storageIsFresh` is whether the license and trial records are both
    /// positively absent, nil while storage has not answered, which decides
    /// nothing yet. Once storage has answered, the decision is recorded
    /// whichever way it went.
    public func shouldTurnOn(isOn: Bool, storageIsFresh: Bool?) -> Bool {
        guard let storageIsFresh, !isDecided else { return false }
        store.set(true, forKey: key)
        return storageIsFresh && !hadPreferences && !isOn
    }
}
