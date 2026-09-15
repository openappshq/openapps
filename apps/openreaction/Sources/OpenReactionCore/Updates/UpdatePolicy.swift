import Foundation

/// Where the running app lives, as far as updating it in place goes.
public enum UpdateLocation: Equatable, Sendable {
    /// A writable location: updates can replace the bundle.
    case updatable
    /// App Translocation: macOS runs a quarantined download from a random
    /// read-only path, so the real bundle cannot be found or replaced.
    case translocated
    /// A read-only volume (a disk image) or a folder this user cannot write.
    case readOnly

    public static func classify(bundlePath: String, volumeIsReadOnly: Bool, containerIsWritable: Bool) -> UpdateLocation {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if volumeIsReadOnly || !containerIsWritable { return .readOnly }
        return .updatable
    }
}

/// When an official build looks for updates on its own (RELEASES.md, "In-app
/// updater"). Automatic checks are off until the user turns them on, so a
/// fresh install never contacts the update feed by itself; "Check now" is
/// always a deliberate request.
public enum UpdatePolicy {
    /// Both Settings toggles start off.
    public static let automaticChecksByDefault = false
    public static let automaticDownloadsByDefault = false

    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// A failed automatic check is retried once after this long; after that
    /// the daily schedule takes over again.
    public static let retryDelay: TimeInterval = 60 * 60

    /// Whether a check the user did not ask for may run now: on launch, on
    /// wake, or for a retry. A last check dated in the future (a clock that
    /// was set back) counts as due rather than postponing checks indefinitely.
    public static func isAutomaticCheckDue(automaticChecks: Bool, location: UpdateLocation, lastCheck: Date?, now: Date) -> Bool {
        guard automaticChecks, location == .updatable else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= checkInterval
    }

    /// The delay before retrying after `consecutiveFailures` failed automatic
    /// checks in a row, or nil when the next attempt is the regular daily one.
    public static func retryDelay(consecutiveFailures: Int) -> TimeInterval? {
        consecutiveFailures == 1 ? retryDelay : nil
    }
}
