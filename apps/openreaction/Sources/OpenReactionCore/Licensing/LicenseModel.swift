import Foundation

/// Which Dodo product a key belongs to, as far as this app is concerned.
public enum LicenseKind: String, Codable, Sendable {
    case paid
    case trial
}

/// The one record an activated Mac keeps (see LICENSING.md, "Stored record").
public struct LicenseRecord: Codable, Equatable, Sendable {
    public var licenseKey: String
    public var instanceID: String
    public var productID: String
    public var kind: LicenseKind
    /// Activation `created_at` (server time).
    public var activatedAt: Date
    /// Time of the last `valid: true` (or the activation), server time when known.
    public var lastSuccessAt: Date
    /// Set when Dodo answered `valid: false` for this activation. Persisted, so
    /// a revoked license stays revoked across restarts and offline launches.
    public var revokedAt: Date?
    /// The latest moment this Mac has observed (server or local), so a clock
    /// rolled back cannot extend a trial or grace.
    public var lastObservedAt: Date

    public init(
        licenseKey: String, instanceID: String, productID: String, kind: LicenseKind,
        activatedAt: Date, lastSuccessAt: Date, revokedAt: Date? = nil, lastObservedAt: Date? = nil
    ) {
        self.licenseKey = licenseKey
        self.instanceID = instanceID
        self.productID = productID
        self.kind = kind
        self.activatedAt = activatedAt
        self.lastSuccessAt = lastSuccessAt
        self.revokedAt = revokedAt
        self.lastObservedAt = lastObservedAt ?? max(activatedAt, lastSuccessAt)
    }

    public var isRevoked: Bool { revokedAt != nil }

    /// The clock the entitlement math uses: never earlier than what this Mac
    /// has already seen, so rolling the clock back changes nothing.
    public func effectiveNow(_ now: Date) -> Date {
        max(now, lastObservedAt)
    }
}

/// The app's product IDs for the current Dodo environment.
public struct LicenseProducts: Equatable, Sendable {
    public var paid: Set<String>
    public var trial: Set<String>

    public init(paid: Set<String>, trial: Set<String>) {
        self.paid = paid
        self.trial = trial
    }

    public func kind(of productID: String) -> LicenseKind? {
        if paid.contains(productID) { return .paid }
        if trial.contains(productID) { return .trial }
        return nil
    }
}

/// What the user sees and whether the core feature runs.
public enum LicenseState: Equatable, Sendable {
    case unlicensed
    case trial(daysLeft: Int)
    case trialEnded
    case licensed
    /// Offline for a while; `daysLeft` until a check is required. The
    /// warning shows after five days offline.
    case grace(daysLeft: Int, showWarning: Bool)
    case checkRequired
    case revoked

    /// "Off" stops only the core feature; everything else keeps working.
    public var isFeatureEnabled: Bool {
        switch self {
        case .trial, .licensed, .grace: true
        case .unlicensed, .trialEnded, .checkRequired, .revoked: false
        }
    }
}

/// Timing rules from LICENSING.md, in one place.
public enum LicensePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    public static let graceDuration: TimeInterval = 7 * 24 * 60 * 60
    public static let graceWarningAfter: TimeInterval = 5 * 24 * 60 * 60
    public static let trialDuration: TimeInterval = 3 * 24 * 60 * 60
    /// A local clock this far behind the last success is a rollback.
    public static let clockRollbackTolerance: TimeInterval = 60 * 60
    public static let minimumRetryDelay: TimeInterval = 60
    public static let maximumRetryDelay: TimeInterval = 60 * 60

    /// Failed checks retry with backoff this many times, then fall back to
    /// the daily schedule.
    public static let maximumRetries = 8

    /// Derives the state from the stored record and the clock.
    public static func state(record: LicenseRecord?, now rawNow: Date) -> LicenseState {
        guard let record else { return .unlicensed }
        if record.isRevoked { return record.kind == .trial ? .trialEnded : .revoked }
        let now = record.effectiveNow(rawNow)
        switch record.kind {
        case .trial:
            let expiry = record.activatedAt.addingTimeInterval(trialDuration)
            guard now < expiry else { return .trialEnded }
            let days = Int(ceil(expiry.timeIntervalSince(now) / 86_400))
            return .trial(daysLeft: min(3, max(1, days)))
        case .paid:
            if rawNow.timeIntervalSince(record.lastSuccessAt) < -clockRollbackTolerance {
                // The clock went backwards: do not let that extend grace.
                return .checkRequired
            }
            let sinceSuccess = now.timeIntervalSince(record.lastSuccessAt)
            if sinceSuccess <= checkInterval {
                return .licensed
            }
            if sinceSuccess <= graceDuration {
                let left = graceDuration - sinceSuccess
                return .grace(daysLeft: max(1, Int(ceil(left / 86_400))), showWarning: sinceSuccess >= graceWarningAfter)
            }
            return .checkRequired
        }
    }

    /// The next moment the state changes without any network activity
    /// (trial expiry, grace warning, grace end, or the daily schedule).
    public static func nextDeadline(record: LicenseRecord?, now rawNow: Date) -> Date? {
        guard let record, !record.isRevoked else { return nil }
        let now = record.effectiveNow(rawNow)
        switch record.kind {
        case .trial:
            let expiry = record.activatedAt.addingTimeInterval(trialDuration)
            return expiry > now ? expiry : nil
        case .paid:
            let candidates = [checkInterval, graceWarningAfter, graceDuration]
                .map { record.lastSuccessAt.addingTimeInterval($0) }
                .filter { $0 > now }
            return candidates.min()
        }
    }

    /// Backoff after `failures` consecutive failed checks: 1 min doubling to 1 h.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 10)
        return min(maximumRetryDelay, minimumRetryDelay * pow(2, Double(exponent)))
    }
}

// MARK: - Dodo client

/// Outcome of `POST /licenses/activate`.
public enum ActivationResult: Equatable, Sendable {
    case activated(Activation)
    /// 404
    case keyNotFound
    /// 403
    case keyDisabledOrExpired
    /// 422
    case activationLimitReached
    case rateLimited(retryAfter: TimeInterval)
    /// 5xx, timeout, no network.
    case unreachable
}

public struct Activation: Equatable, Sendable {
    public var instanceID: String
    public var productID: String
    public var productName: String
    public var createdAt: Date
    /// The response `Date` header, if present.
    public var serverDate: Date?

    public init(instanceID: String, productID: String, productName: String, createdAt: Date, serverDate: Date? = nil) {
        self.instanceID = instanceID
        self.productID = productID
        self.productName = productName
        self.createdAt = createdAt
        self.serverDate = serverDate
    }
}

/// Outcome of `POST /licenses/validate`.
public enum ValidationResult: Equatable, Sendable {
    case valid(serverDate: Date?)
    /// Authoritative: refunded, disabled, expired, or this Mac was removed.
    case invalid
    case rateLimited(retryAfter: TimeInterval)
    case unreachable
}

/// Outcome of `POST /licenses/deactivate`.
public enum DeactivationResult: Equatable, Sendable {
    case deactivated
    case rateLimited(retryAfter: TimeInterval)
    case unreachable
}

/// Dodo Payments' public license endpoints. No API key, no secrets.
public protocol LicenseClient: Sendable {
    func activate(licenseKey: String, name: String) async -> ActivationResult
    func validate(licenseKey: String, instanceID: String) async -> ValidationResult
    func deactivate(licenseKey: String, instanceID: String) async -> DeactivationResult
}

/// Storage that could not be read or written. Distinct from "no record".
public enum LicenseStoreError: Error, Equatable, Sendable {
    /// The Keychain is locked, denied or otherwise unavailable.
    case unavailable(String)
    /// A record exists but could not be decoded.
    case corrupt
}

/// Where the record lives (the Keychain in the app; memory in tests). Every
/// operation reports failure instead of pretending it worked.
public protocol LicenseStore: Sendable {
    func loadRecord() throws(LicenseStoreError) -> LicenseRecord?
    func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError)
    func clearRecord() throws(LicenseStoreError)
    /// Set when a trial key is first activated on this Mac; kept after removal.
    func loadTrialUsed() throws(LicenseStoreError) -> Bool
    func markTrialUsed() throws(LicenseStoreError)
}

// MARK: - User-facing messages

/// Errors and notices in the words the License screen shows.
public enum LicenseMessage: Equatable, Sendable {
    case keyNotFound
    case keyDisabledOrExpired
    case allMacsActivated
    case unreachable
    case rateLimited(seconds: Int)
    case wrongProduct(productName: String)
    case trialAlreadyUsed
    case removeFailedOffline
    case activated(LicenseKind)
    case removed
    /// The record could not be saved; the new activation was given back.
    case storageFailed
    /// The stored record could not be read.
    case storageUnavailable
    /// A previous activation could not be freed yet; retried automatically.
    case cleanupPending
    case alreadyActivated
    /// Dodo's answer was missing something the contract requires.
    case malformedResponse

    public var text: String {
        switch self {
        case .keyNotFound: "Key not found. Check for typos, or paste the key from your email."
        case .keyDisabledOrExpired: "This key is disabled or has expired."
        case .allMacsActivated: "All 3 Macs for this license are already activated. Remove one in OpenReaction on that Mac, or contact support."
        case .unreachable: "Couldn’t reach the license service. Check your connection and try again."
        case .rateLimited(let seconds): "Too many attempts. Try again in \(seconds) seconds."
        case .wrongProduct(let productName): "This key is for \(productName), not OpenReaction."
        case .trialAlreadyUsed: "The trial was already used on this Mac."
        case .removeFailedOffline: "Couldn’t reach the license service to remove this Mac. Try again when you’re online."
        case .activated(.paid): "OpenReaction is licensed on this Mac."
        case .activated(.trial): "Your 3-day trial has started."
        case .removed: "This Mac was removed from the license."
        case .storageFailed: "OpenReaction couldn’t save the license on this Mac (the Keychain refused). The activation was released; unlock the Keychain and try again."
        case .storageUnavailable: "OpenReaction can’t read its license from the Keychain right now."
        case .cleanupPending: "A previous activation couldn’t be released yet; OpenReaction will retry. If a Mac stays counted, contact support."
        case .alreadyActivated: "This key is already active on this Mac."
        case .malformedResponse: "The license service sent an unexpected answer. Try again later."
        }
    }
}

/// The one place the app asks whether the core feature may run. A build with
/// licensing compiled out has no manager: everything is on and nothing is
/// ever called.
public enum LicenseGate {
    @MainActor
    public static func isFeatureEnabled(_ manager: LicenseManager?) -> Bool {
        manager?.isFeatureEnabled ?? true
    }
}
