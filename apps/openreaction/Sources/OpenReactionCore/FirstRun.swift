import Foundation

/// The few flags the app keeps between launches for first-run decisions.
/// `UserDefaults` conforms as is; tests use a dictionary.
public protocol FlagStore {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: FlagStore {}

/// When the setup window opens on its own: once, on the first launch, and
/// after a relaunch the window itself started. Afterwards it is reached
/// from Settings ("Show setup guide"), the status menu, or by opening the
/// app again while setup is incomplete; it never opens by itself again.
public enum OnboardingLaunch {
    public enum Key {
        public static let shown = "onboarding.shown"
        public static let resumeAfterRelaunch = "onboarding.resumeAfterRelaunch"
    }

    /// Consumes the relaunch marker.
    public static func shouldShow(store: any FlagStore) -> Bool {
        let resume = store.bool(forKey: Key.resumeAfterRelaunch)
        store.removeObject(forKey: Key.resumeAfterRelaunch)
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
}

/// "Open at login" defaults to on in official builds: the login item is
/// registered once, on the first launch that finds it unregistered. The
/// default never runs again, so a later "off" — in Settings or in System
/// Settings — is never undone.
public enum LoginItemDefault {
    public enum Key {
        /// The default was applied (or found unnecessary); never again.
        public static let applied = "loginItem.defaultApplied"
    }

    /// Whether to register now. Records that the default was considered.
    public static func shouldRegister(store: any FlagStore, isRegistered: Bool) -> Bool {
        guard !store.bool(forKey: Key.applied) else { return false }
        store.set(true, forKey: Key.applied)
        return !isRegistered
    }
}
