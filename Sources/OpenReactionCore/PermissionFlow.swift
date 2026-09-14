import Foundation

/// The two macOS privacy permissions OpenReaction needs.
public enum PermissionKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Accessibility: read the focused element's caret and post typed emoji.
    case accessibility
    /// Input Monitoring: receive key events from the session event tap.
    case inputMonitoring
}

/// What the user should be told about one permission.
public enum PermissionStatus: Equatable, Sendable {
    /// Not granted and never asked for in this run.
    case missing
    /// System Settings was opened for it; waiting for the user to flip the switch.
    case requested
    /// macOS reports it granted and nothing suggests the grant is not working.
    case granted
    /// macOS reports it granted, but the event tap still cannot start. A fresh
    /// process usually picks the grant up.
    case needsRelaunch
    /// The permission list most likely holds an entry that does not match this
    /// copy of OpenReaction (TCC keys grants to the code signature), so the
    /// switch the user sees does not apply. Resetting the entry fixes it.
    case stale
}

/// Reads live permission state. The app uses `AXIsProcessTrusted` and
/// `CGPreflightListenEventAccess`; tests inject fixed answers.
public protocol PermissionProvider {
    func isGranted(_ kind: PermissionKind) -> Bool
}

public protocol FlowClock {
    var now: Date { get }
}

public struct SystemClock: FlowClock {
    public init() {}
    public var now: Date { Date() }
}

/// Steps of the first-run window, in order.
public enum OnboardingStep: Int, CaseIterable, Comparable, Sendable {
    case welcome
    case accessibility
    case inputMonitoring
    case tryIt
    case done

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var permission: PermissionKind? {
        switch self {
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        default: nil
        }
    }
}

/// Permission state machine.
///
/// Inputs are live reads from a `PermissionProvider` (`refresh()`), the user
/// opening System Settings (`didRequest`), the event tap's start results
/// (`recordTap`), a relaunch (`willRelaunch`) and a TCC reset (`didReset`).
/// `status(of:)` and `onboardingStep(...)` derive everything the UI shows.
///
/// ## Status rules, per permission
///
/// When macOS reports the permission granted:
/// - **needsRelaunch** while the tap is failing: both permissions report
///   granted, the app tried to start the tap and it failed at least
///   `tapFailureThreshold` times in a row, or at least twice with the first
///   failure `tapFailureGrace` ago (so slow background polling still gets
///   there). Applies to both permissions, since a failing tap cannot say which
///   grant is ineffective.
/// - **stale** instead of needsRelaunch when the tap is failing and the app
///   already relaunched for this within `relaunchWindow`: a fresh process did
///   not help, so the grant itself is suspect.
/// - **granted** otherwise.
///
/// When macOS reports it not granted:
/// - **stale** when `Memory.grantedIdentity` holds a code identity for this
///   permission that differs from the running one: it was granted on this
///   install to an earlier build (an update or re-sign), and macOS now refuses
///   it, which is what a signature mismatch looks like. Seeing the permission
///   not granted while the identity is unchanged means the user revoked it, so
///   the memory is dropped and the status is missing/requested.
/// - **requested** after `didRequest` until it is granted or reset.
/// - **missing** otherwise.
///
/// Known false positive: a grant revoked while OpenReaction was not running,
/// followed by an update, reads as stale. The recovery offered for stale
/// (reset, then request again) also works for that case.
public struct PermissionFlow {
    public struct Configuration: Equatable, Sendable {
        public var tapFailureThreshold: Int
        public var tapFailureGrace: TimeInterval
        public var relaunchWindow: TimeInterval

        public init(tapFailureThreshold: Int = 3, tapFailureGrace: TimeInterval = 5, relaunchWindow: TimeInterval = 300) {
            self.tapFailureThreshold = tapFailureThreshold
            self.tapFailureGrace = tapFailureGrace
            self.relaunchWindow = relaunchWindow
        }
    }

    /// State that must survive a relaunch or an update. Persist it after every mutation.
    public struct Memory: Codable, Equatable, Sendable {
        /// Code identity of the build that last saw each permission granted.
        public var grantedIdentity: [PermissionKind: String]
        /// When the app last relaunched itself because the tap would not start.
        public var relaunchedAt: Date?

        public init(grantedIdentity: [PermissionKind: String] = [:], relaunchedAt: Date? = nil) {
            self.grantedIdentity = grantedIdentity
            self.relaunchedAt = relaunchedAt
        }
    }

    public private(set) var memory: Memory
    public let codeIdentity: String
    public let configuration: Configuration

    private let provider: any PermissionProvider
    private let clock: any FlowClock
    private var reported: [PermissionKind: Bool] = [:]
    private var requested: Set<PermissionKind> = []
    private var tapFailures = 0
    private var tapFailingSince: Date?

    public init(
        provider: any PermissionProvider,
        clock: any FlowClock = SystemClock(),
        codeIdentity: String,
        memory: Memory = Memory(),
        configuration: Configuration = Configuration()
    ) {
        self.provider = provider
        self.clock = clock
        self.codeIdentity = codeIdentity
        self.memory = memory
        self.configuration = configuration
        refresh()
    }

    // MARK: - Inputs

    /// Reads live state. Returns true when any reported value changed.
    @discardableResult
    public mutating func refresh() -> Bool {
        var changed = false
        for kind in PermissionKind.allCases {
            let granted = provider.isGranted(kind)
            if reported[kind] != granted {
                reported[kind] = granted
                changed = true
            }
            if granted {
                requested.remove(kind)
                memory.grantedIdentity[kind] = codeIdentity
            } else if memory.grantedIdentity[kind] == codeIdentity {
                // Revoked on this very build: a plain "missing", not a stale entry.
                memory.grantedIdentity[kind] = nil
            }
        }
        if !allReportedGranted {
            tapFailures = 0
            tapFailingSince = nil
        }
        return changed
    }

    /// The user was sent to System Settings for `kind`.
    public mutating func didRequest(_ kind: PermissionKind) {
        refresh()
        if reported[kind] != true { requested.insert(kind) }
    }

    /// The app reset the TCC entry for `kind`; start over from missing.
    public mutating func didReset(_ kind: PermissionKind) {
        memory.grantedIdentity[kind] = nil
        memory.relaunchedAt = nil
        requested.remove(kind)
        tapFailures = 0
        tapFailingSince = nil
        refresh()
    }

    /// Result of trying to start the event tap. Only report attempts: a tap
    /// the user paused is neither running nor failing.
    public mutating func recordTap(running: Bool) {
        if running {
            tapFailures = 0
            tapFailingSince = nil
            memory.relaunchedAt = nil
        } else if allReportedGranted {
            tapFailures += 1
            if tapFailingSince == nil { tapFailingSince = clock.now }
        }
    }

    /// Call right before relaunching because of `needsRelaunch`.
    public mutating func willRelaunch() {
        memory.relaunchedAt = clock.now
    }

    /// The relaunch could not start a new instance; this process keeps running.
    public mutating func relaunchFailed() {
        memory.relaunchedAt = nil
    }

    // MARK: - Derived state

    public func isReportedGranted(_ kind: PermissionKind) -> Bool {
        reported[kind] ?? false
    }

    public var allReportedGranted: Bool {
        PermissionKind.allCases.allSatisfy(isReportedGranted)
    }

    /// Both permissions report granted but the tap will not start.
    public var isTapFailing: Bool {
        guard allReportedGranted, tapFailures > 0 else { return false }
        if tapFailures >= configuration.tapFailureThreshold { return true }
        guard tapFailures >= 2, let since = tapFailingSince else { return false }
        return clock.now.timeIntervalSince(since) >= configuration.tapFailureGrace
    }

    private var relaunchedRecently: Bool {
        guard let relaunchedAt = memory.relaunchedAt else { return false }
        return clock.now.timeIntervalSince(relaunchedAt) < configuration.relaunchWindow
    }

    public func status(of kind: PermissionKind) -> PermissionStatus {
        if isReportedGranted(kind) {
            guard isTapFailing else { return .granted }
            return relaunchedRecently ? .stale : .needsRelaunch
        }
        if let identity = memory.grantedIdentity[kind], identity != codeIdentity {
            return .stale
        }
        return requested.contains(kind) ? .requested : .missing
    }

    /// Every permission is granted and working as far as the app can tell.
    public var isComplete: Bool {
        PermissionKind.allCases.allSatisfy { status(of: $0) == .granted }
    }

    /// Any status other than granted.
    public var needsAttention: Bool { !isComplete }

    /// Where the onboarding window should be.
    ///
    /// - welcome until the user starts;
    /// - the first permission macOS does not report granted, in order;
    /// - tryIt once both report granted — including while the tap is failing,
    ///   since relaunch and reset are offered there — until practice finished;
    /// - done afterwards.
    public func onboardingStep(hasStarted: Bool, practiceFinished: Bool) -> OnboardingStep {
        guard hasStarted else { return .welcome }
        if !isReportedGranted(.accessibility) { return .accessibility }
        if !isReportedGranted(.inputMonitoring) { return .inputMonitoring }
        if isTapFailing || !practiceFinished { return .tryIt }
        return .done
    }
}
