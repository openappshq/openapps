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
    /// How long the pointer rests on the notch before a hover opens, in seconds.
    public static let hoverDelay = "notch.hoverDelay"
    public static let hotkey = "notch.hotkey"
    public static let shuffleInterval = "shuffle.interval"
    public static let favoritesOnly = "shuffle.favoritesOnly"
    public static let sameOnAllDisplays = "apply.sameOnAllDisplays"
    public static let exportFolder = "export.folder"
    public static let keepApplied = "apply.keepApplied"
    public static let clockStyle = "clock.style"
    public static let clockPosition = "clock.position"
    public static let clockSize = "clock.size"
    /// The parameters pinned against Shuffle, as JSON.
    public static let pins = "shuffle.pins"

    public static let all: [String] = [
        notchEnabled, hostDisplay, trigger, direction, width, hideInFullscreen, hoverDelay, hotkey,
        shuffleInterval, favoritesOnly, sameOnAllDisplays, exportFolder,
        keepApplied, clockStyle, clockPosition, clockSize, pins,
    ]
}

/// The setup guide's steps. macPaper asks for no permission, so the guide
/// never waits on the system: the step shown is the user's own progress,
/// kept so "Show setup guide" resumes where they left off. The raw value
/// is what the flag stores, so it never changes for a step; `order` is
/// what the guide walks, and a step added later goes where it belongs
/// in `order` with the next free raw value.
public enum GuideStep: Int, CaseIterable, Comparable, Sendable {
    case welcome = 0
    /// "Nothing to grant": what macPaper touches, and that no permission is needed.
    case permissions = 1
    /// "Starts with your Mac": the login item, from its real state.
    case loginItem = 2
    case tips = 3
    /// "Where the panel lives": the notch hover zone and the panel dropping
    /// from it, or the menu-bar item on a Mac without a notch.
    case panel = 4

    /// The steps as the guide walks them.
    public static let order: [GuideStep] = [.welcome, .panel, .permissions, .loginItem, .tips]

    /// The step's place in the walk.
    public var index: Int { Self.order.firstIndex(of: self) ?? 0 }

    public static func < (lhs: GuideStep, rhs: GuideStep) -> Bool { lhs.index < rhs.index }

    public var next: GuideStep? { Self.order.indices.contains(index + 1) ? Self.order[index + 1] : nil }
    public var previous: GuideStep? { index > 0 ? Self.order[index - 1] : nil }
    public var isLast: Bool { next == nil }
}

/// When the setup guide opens on its own: once, on the first launch of a
/// packaged app. Afterwards it is reached from Settings ("Show setup
/// guide"); a guide the user closed never opens by itself again, and
/// reopening it resumes at the step they left.
public enum OnboardingLaunch {
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

/// The glow under the notch that shows where the panel is triggered, for
/// the first launches only: it pulses when the pointer comes within
/// `PanelLayout.hintReach` of the notch, on the first `launchesShown`
/// launches, and never again once the notch has opened the panel once
/// (by hover or by click). The flags live beside the first-run flags.
public enum NotchHint {
    public enum Key {
        /// How many launches have counted so far.
        public static let launches = "notchHint.launches"
        /// The notch opened the panel once: the hint is done.
        public static let used = "notchHint.used"
    }

    /// The hint shows on this many launches.
    public static let launchesShown = 5

    /// Counts a launch; called once per launch, after the fresh-install
    /// evidence has been read (the count is evidence of an earlier launch)
    /// and before `isArmed` is asked.
    public static func recordLaunch(store: any FlagStore) {
        store.set(store.integer(forKey: Key.launches) + 1, forKey: Key.launches)
    }

    /// The panel opened from the notch: nothing left to show.
    public static func markUsed(store: any FlagStore) {
        store.set(true, forKey: Key.used)
    }

    /// Whether the glow is armed this launch: the notch has never opened
    /// the panel, and this launch (counted already) is one of the first
    /// `launchesShown`. An uncounted launch (0) counts as the first.
    public static func isArmed(store: any FlagStore) -> Bool {
        !store.bool(forKey: Key.used) && store.integer(forKey: Key.launches) <= launchesShown
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
            [OnboardingLaunch.Key.shown, OnboardingLaunch.Key.step, NotchHint.Key.launches, NotchHint.Key.used, loginItemApplied, updateChecksApplied]
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
