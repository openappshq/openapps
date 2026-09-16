import Foundation

/// The few flags the app keeps between launches for first-run decisions.
/// `UserDefaults` conforms as is; tests use a dictionary.
public protocol FlagStore {
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func set(_ value: Bool, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func removeObject(forKey key: String)
    /// Whether anything at all is stored under `key`, whatever its type or
    /// value: a stored `false` counts.
    func hasValue(forKey key: String) -> Bool
}

extension UserDefaults: FlagStore {
    public func hasValue(forKey key: String) -> Bool { object(forKey: key) != nil }
}

/// Every preference the app writes to its standard defaults domain. The
/// names are here, beside the fresh-install rule, because any one present
/// at launch means an earlier launch happened; the app's `Preferences`
/// reads and writes the same names.
public enum PreferenceKey {
    public static let notchEnabled = "notch.enabled"
    public static let hostDisplay = "notch.hostDisplay"
    public static let trigger = "notch.trigger"
    public static let direction = "notch.direction"
    public static let width = "notch.width"
    public static let hideInFullscreen = "notch.hideInFullscreen"
    public static let hotkey = "notch.hotkey"
    public static let shuffleInterval = "shuffle.interval"
    public static let favoritesOnly = "shuffle.favoritesOnly"
    public static let sameOnAllDisplays = "apply.sameOnAllDisplays"
    public static let exportFolder = "export.folder"

    public static let all: [String] = [
        notchEnabled, hostDisplay, trigger, direction, width, hideInFullscreen, hotkey,
        shuffleInterval, favoritesOnly, sameOnAllDisplays, exportFolder,
    ]
}

/// When the setup guide opens on its own: once, on the first launch of a
/// packaged app. The guide itself is a later ticket; the flag is here so
/// the fresh-install rule already counts it.
public enum OnboardingLaunch {
    public enum Key {
        public static let shown = "onboarding.shown"
        public static let step = "onboarding.step"
    }

    public static func shouldShow(store: any FlagStore) -> Bool {
        !store.bool(forKey: Key.shown)
    }

    public static func markShown(store: any FlagStore) {
        store.set(true, forKey: Key.shown)
    }
}

/// A setting official builds turn on once, on a demonstrably fresh install:
/// no preferences from an earlier launch (of any version), and neither a
/// trial nor a license record in the record store, both positively absent.
/// Anything else — an upgrade, a reinstall over kept records, a setting the
/// user once turned off — is left alone. Decided once; the flag makes every
/// later launch leave the setting as is. Two settings follow this rule
/// (RELEASES.md, "In-app updater"): "Open at login" and "Check for updates
/// automatically". The same rule as Hertz's and OpenReaction's.
public struct FreshInstallDefault {
    public enum Key {
        /// The login-item default was applied (or found unnecessary); never again.
        public static let loginItemApplied = "loginItem.defaultApplied"
        /// The automatic-update-check default was applied (or found unnecessary); never again.
        public static let updateChecksApplied = "updates.checkDefaultApplied"

        /// Every preference the app writes to its standard defaults domain
        /// (the updater's included): any one present at launch, whatever its
        /// value, is an earlier launch's preferences, and the install is not
        /// fresh. A stored `false` toggle is a choice, so presence is what
        /// counts. The list is by hand; add a key here when the app starts
        /// writing a new one.
        public static let earlierPreferenceEvidence: [String] =
            [OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step, loginItemApplied, updateChecksApplied]
            + PreferenceKey.all
            + ["OpenAppsUpdater.checkAutomatically", "OpenAppsUpdater.installAutomatically", "OpenAppsUpdater.lastCheck"]
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
    /// An earlier launch left preferences behind: any of
    /// `Key.earlierPreferenceEvidence` is stored. Read when this is created,
    /// at launch, before the current launch writes any.
    public let hadPreferences: Bool

    public init(store: any FlagStore, key: String) {
        self.store = store
        self.key = key
        hadPreferences = Key.earlierPreferenceEvidence.contains { store.hasValue(forKey: $0) }
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
    /// positively absent (a source build, with no record store, passes
    /// `true`), nil while storage has not answered, which decides nothing
    /// yet. Once storage has answered, the decision is recorded whichever
    /// way it went.
    public func shouldTurnOn(isOn: Bool, storageIsFresh: Bool?) -> Bool {
        guard let storageIsFresh, !isDecided else { return false }
        store.set(true, forKey: key)
        return storageIsFresh && !hadPreferences && !isOn
    }
}
