import Foundation

/// The few flags the app keeps between launches for first-run decisions.
/// `UserDefaults` conforms as is; tests use a dictionary.
nonisolated public protocol FlagStore {
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

/// The setup guide's steps, in order. Hertz asks for no permission, so the
/// guide never waits on the system: the step shown is the user's own
/// progress, kept so "Show setup guide" resumes where they left off.
nonisolated public enum GuideStep: Int, CaseIterable, Comparable, Sendable {
    case welcome
    /// "Nothing to grant": what Hertz reads, and that no permission is needed.
    case permissions
    /// "Starts with your Mac": the login item, from its real state.
    case loginItem
    case tips

    public static func < (lhs: GuideStep, rhs: GuideStep) -> Bool { lhs.rawValue < rhs.rawValue }

    public var next: GuideStep? { GuideStep(rawValue: rawValue + 1) }
    public var previous: GuideStep? { GuideStep(rawValue: rawValue - 1) }
    public var isLast: Bool { next == nil }
}

/// When the setup guide opens on its own: once, on the first launch of a
/// packaged app. Afterwards it is reached from Settings ("Show setup
/// guide"); a guide the user closed never opens by itself again, and
/// reopening it resumes at the step they left.
nonisolated public enum OnboardingLaunch {
    public enum Key {
        public static let shown = "onboarding.shown"
        /// The furthest step the user reached; the guide resumes there.
        public static let step = "onboarding.step"
    }

    public static func shouldShow(store: any FlagStore) -> Bool {
        !store.bool(forKey: Key.shown)
    }

    /// The guide was shown (by anyone): it no longer opens on launch.
    public static func markShown(store: any FlagStore) {
        store.set(true, forKey: Key.shown)
    }

    /// The step to open at: the saved one, the first when nothing is saved
    /// or the saved value is not a step. Finishing the guide saves nothing
    /// past the last step, so a finished guide reopens at its tips.
    public static func resumeStep(store: any FlagStore) -> GuideStep {
        GuideStep(rawValue: store.integer(forKey: Key.step)) ?? .welcome
    }

    /// Only ever moves forward: going back to re-read a step does not lose
    /// the progress made.
    public static func markReached(_ step: GuideStep, store: any FlagStore) {
        if step > resumeStep(store: store) { store.set(step.rawValue, forKey: Key.step) }
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
nonisolated public struct FreshInstallDefault {
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
        public static let earlierPreferenceEvidence: [String] = [
            // OnboardingLaunch
            OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step,
            // These defaults' own flags: either decided means an earlier launch resolved it.
            loginItemApplied, updateChecksApplied,
            // Preferences: the readout, the visible cards.
            "menuBarReadout", "showsDiagnosis", "showsSleepBlockers", "showsProcesses", "showsCleanupScout",
            // OpenAppsUpdater (Updater.Key): both toggles and the last check.
            "OpenAppsUpdater.checkAutomatically", "OpenAppsUpdater.installAutomatically", "OpenAppsUpdater.lastCheck",
            // Releases before licensing: the one-screen welcome and the login
            // item's first-launch flag. Either present is an upgrade.
            "didShowWelcome", "didDefaultOpenAtLogin",
        ]
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
    /// positively absent, nil while storage has not answered, which decides
    /// nothing yet. Once storage has answered, the decision is recorded
    /// whichever way it went.
    public func shouldTurnOn(isOn: Bool, storageIsFresh: Bool?) -> Bool {
        guard let storageIsFresh, !isDecided else { return false }
        store.set(true, forKey: key)
        return storageIsFresh && !hadPreferences && !isOn
    }
}
