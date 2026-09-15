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

/// "Open at login" defaults to on in official builds, but only on a
/// demonstrably fresh install: no preferences from an earlier launch (of
/// any version), and neither a trial nor a license record in the Keychain,
/// both positively absent. Anything else — an upgrade, a reinstall over a
/// kept Keychain, a login item the user once turned off — is left alone.
/// Decided once; the flag makes every later launch leave the item as is.
public struct LoginItemDefault {
    public enum Key {
        /// The default was applied (or found unnecessary); never again.
        public static let applied = "loginItem.defaultApplied"
    }

    private let store: any FlagStore
    /// An earlier launch left preferences behind. Read when this is created,
    /// at launch, before the current launch writes any.
    public let hadPreferences: Bool

    public init(store: any FlagStore) {
        self.store = store
        hadPreferences = store.bool(forKey: OnboardingLaunch.Key.shown)
    }

    /// Whether to register now. `storageIsFresh` is whether the license and
    /// trial records are both positively absent; nil while storage has not
    /// answered, which decides nothing yet. Once storage has answered, the
    /// decision is recorded whichever way it went.
    public func shouldRegister(isRegistered: Bool, storageIsFresh: Bool?) -> Bool {
        guard let storageIsFresh, !store.bool(forKey: Key.applied) else { return false }
        store.set(true, forKey: Key.applied)
        return storageIsFresh && !hadPreferences && !isRegistered
    }
}
