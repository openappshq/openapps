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

    /// The running bundle's location.
    public static func current(bundleURL: URL, fileManager: FileManager = .default) -> UpdateLocation {
        let volumeReadOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let container = bundleURL.deletingLastPathComponent().path
        let writable = fileManager.isWritableFile(atPath: container) && fileManager.isWritableFile(atPath: bundleURL.path)
        return classify(bundlePath: bundleURL.path, volumeIsReadOnly: volumeReadOnly, containerIsWritable: writable)
    }
}

/// A release version, `MAJOR.MINOR.PATCH`. Its build number
/// (`CFBundleVersion`) is derived from it, so build order is release order:
/// a back-port with a later commit can never look newer than the release it
/// patches, and two versions cut from one commit never share a build.
public struct UpdateVersion: Equatable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Strict `MAJOR.MINOR.PATCH`, each part at most 999; anything else is nil.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part), number <= 999 else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// `MAJOR * 1_000_000 + MINOR * 1_000 + PATCH`, what the apps' bundle
    /// scripts stamp as `CFBundleVersion`.
    public var buildNumber: Int { major * 1_000_000 + minor * 1_000 + patch }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// How an update came to be downloaded.
public enum UpdateConsent: Equatable, Sendable {
    /// Downloaded by the automatic schedule, under "Download and install automatically".
    case automatic
    /// The user chose to install it after "Check now".
    case manual
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

    /// Whether a feed item is an update for the running app: same app and
    /// channel, a macOS this Mac meets, and strictly newer by version *and*
    /// build, with the build derived from the version. Apps never downgrade,
    /// and a feed whose build order disagrees with its version order is not
    /// trusted either way.
    public static func offers(
        _ item: UpdateFeedItem, app: String, channel: String,
        currentVersion: UpdateVersion, currentBuild: Int, macOSVersion: OperatingSystemVersion
    ) -> Bool {
        guard item.app == app, item.channel == channel else { return false }
        guard item.version > currentVersion, item.build > currentBuild else { return false }
        guard item.build == item.version.buildNumber else { return false }
        return item.minimumMacOS <= macOSVersion
    }

    /// Whether a staged update may be installed when the app quits. An
    /// update staged by an automatic download installs only while
    /// "Download and install automatically" is still on: turning it off
    /// withdraws consent. One the user asked for (Check now → Install) keeps
    /// its consent.
    public static func mayInstallOnQuit(consent: UpdateConsent, automaticDownloads: Bool) -> Bool {
        switch consent {
        case .automatic: automaticDownloads
        case .manual: true
        }
    }

    /// Whether a download URL may be used: https, or plain http to the
    /// loopback address for local update tests only.
    public static func allows(downloadURL url: URL, insecureLoopback: Bool) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return insecureLoopback && url.host == "127.0.0.1"
        default: return false
        }
    }
}

extension OperatingSystemVersion: @retroactive Equatable, @retroactive Comparable {
    public static func == (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion) == (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }

    public static func < (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion) < (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }

    /// `14`, `14.2` or `14.2.1`; anything else is nil.
    public init?(parsing string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(majorVersion: numbers[0], minorVersion: numbers[1], patchVersion: numbers[2])
    }
}
