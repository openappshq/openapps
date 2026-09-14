import Foundation

/// The license record an activated Mac keeps (see LICENSING.md, "Stored
/// records"). The trial has a record of its own (`TrialRecord`).
public struct LicenseRecord: Codable, Equatable, Sendable {
    public var licenseKey: String
    public var instanceID: String
    public var productID: String
    /// Activation `created_at` (server time).
    public var activatedAt: Date
    /// Time of the last `valid: true` (or the activation), server time when known.
    public var lastSuccessAt: Date
    /// Set when Dodo answered `valid: false` for this activation. Persisted, so
    /// a revoked license stays revoked across restarts and offline launches.
    public var revokedAt: Date?
    /// The latest moment this Mac has observed (server time when a check
    /// succeeds, else local), so a clock rolled back is detected.
    public var lastObservedAt: Date
    /// Incremented on every authoritative change (activation, `valid: true`,
    /// revocation, removal). The invalidation journal refers to it, so
    /// staleness is decided by order, never by comparing clocks.
    public var eventSeq: UInt64
    /// Read from a record saved as `kind: trial` before the trial moved
    /// in-app. Never written: such a record is not a license.
    public private(set) var isLegacyTrial = false

    public init(
        licenseKey: String, instanceID: String, productID: String,
        activatedAt: Date, lastSuccessAt: Date, revokedAt: Date? = nil, lastObservedAt: Date? = nil, eventSeq: UInt64 = 1
    ) {
        self.licenseKey = licenseKey
        self.instanceID = instanceID
        self.productID = productID
        self.activatedAt = activatedAt
        self.lastSuccessAt = lastSuccessAt
        self.revokedAt = revokedAt
        self.lastObservedAt = lastObservedAt ?? max(activatedAt, lastSuccessAt)
        self.eventSeq = eventSeq
    }

    /// Records saved before the sequence existed read as 0, so any journal
    /// entry about them is honored. A `kind` from before the trial moved
    /// in-app is read only to recognise a retired trial record.
    public init(from decoder: Decoder) throws {
        isLegacyTrial = (try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .kind)) == "trial"
        let container = try decoder.container(keyedBy: CodingKeys.self)
        licenseKey = try container.decode(String.self, forKey: .licenseKey)
        instanceID = try container.decode(String.self, forKey: .instanceID)
        productID = try container.decode(String.self, forKey: .productID)
        activatedAt = try container.decode(Date.self, forKey: .activatedAt)
        lastSuccessAt = try container.decode(Date.self, forKey: .lastSuccessAt)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
        lastObservedAt = try container.decodeIfPresent(Date.self, forKey: .lastObservedAt) ?? max(activatedAt, lastSuccessAt)
        eventSeq = try container.decodeIfPresent(UInt64.self, forKey: .eventSeq) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case licenseKey, instanceID, productID, activatedAt, lastSuccessAt, revokedAt, lastObservedAt, eventSeq
    }

    private enum LegacyKeys: String, CodingKey {
        case kind
    }

    public var isRevoked: Bool { revokedAt != nil }

    /// The wall clock is materially earlier than time this Mac already saw.
    public func clockRolledBack(now: Date) -> Bool {
        now < lastObservedAt.addingTimeInterval(-LicensePolicy.clockRollbackTolerance)
    }
}

/// The app's paid product IDs for the current Dodo environment. Anything
/// else — another app's key, the wrong environment, a retired trial
/// product — is refused.
public struct LicenseProducts: Equatable, Sendable {
    public var paid: Set<String>

    public init(paid: Set<String>) {
        self.paid = paid
    }

    public func isPaid(_ productID: String) -> Bool {
        paid.contains(productID)
    }
}

/// What the user sees and whether the core feature runs.
public enum LicenseState: Equatable, Sendable {
    /// No license, and no trial can run yet: storage has not been read, the
    /// trial record cannot be read or saved, or the license record cannot
    /// be read.
    case trialUnavailable
    /// `daysLeft` rounded up; 1 means the final day ("less than a day left").
    case trial(daysLeft: Int)
    /// An unregistered trial past its offline limit: "Connect to the
    /// internet to continue your free trial".
    case trialNeedsConnection
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
        case .trialUnavailable, .trialNeedsConnection, .trialEnded, .checkRequired, .revoked: false
        }
    }
}

/// Timing rules from LICENSING.md, in one place.
public enum LicensePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    public static let graceDuration: TimeInterval = 7 * 24 * 60 * 60
    public static let graceWarningAfter: TimeInterval = 5 * 24 * 60 * 60
    /// A local clock this far behind the last success is a rollback.
    public static let clockRollbackTolerance: TimeInterval = 60 * 60
    public static let minimumRetryDelay: TimeInterval = 60
    public static let maximumRetryDelay: TimeInterval = 60 * 60
    /// A running trial's `last_seen_at` is saved at most this often.
    public static let trialSaveInterval: TimeInterval = 60 * 60

    /// Failed checks retry with backoff this many times, then fall back to
    /// the daily schedule.
    public static let maximumRetries = 8

    /// Derives the state of a paid license from its record and the clock. A
    /// clock that went backwards fails closed: the license needs a check
    /// until a successful check re-anchors time.
    public static func state(record: LicenseRecord, now: Date) -> LicenseState {
        if record.isRevoked { return .revoked }
        if record.clockRolledBack(now: now) || now.timeIntervalSince(record.lastSuccessAt) < -clockRollbackTolerance {
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

    /// Derives the trial's state: ended at `duration` of elapsed time, and an
    /// unregistered trial stops at its offline limit until the registry answers.
    public static func trialState(_ trial: TrialRecord, timing: TrialTiming, now: Date) -> LicenseState {
        let elapsed = trial.elapsed(now: now)
        if elapsed >= timing.duration { return .trialEnded }
        if !trial.registered, elapsed >= timing.offlineLimit { return .trialNeedsConnection }
        let days = Int(ceil((timing.duration - elapsed) / timing.day))
        return .trial(daysLeft: min(3, max(1, days)))
    }

    /// The next moment the state changes without any network activity
    /// (grace warning, grace end, or the daily schedule).
    public static func nextDeadline(record: LicenseRecord, now: Date) -> Date? {
        guard !record.isRevoked, !record.clockRolledBack(now: now) else { return nil }
        let candidates = [checkInterval, graceWarningAfter, graceDuration]
            .map { record.lastSuccessAt.addingTimeInterval($0) }
            .filter { $0 > now }
        return candidates.min()
    }

    /// The next moment the trial's state changes on the local clock: a
    /// day boundary (days left, the offline limit) or the end. Elapsed time
    /// only moves once the clock is past `last_seen_at`.
    public static func nextTrialDeadline(_ trial: TrialRecord, timing: TrialTiming, now: Date) -> Date? {
        let observed = max(now, trial.lastSeenAt)
        return (1...3).map { trial.startedAt.addingTimeInterval(Double($0) * timing.day) }
            .filter { $0 > observed }
            .min()
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
    /// A 2xx answer missing something the contract requires (id, product, created_at).
    case malformed
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
    /// Activations that still have to be deactivated (foreign keys, replaced
    /// keys); kept until Dodo confirms.
    func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup]
    func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError)
}

/// A non-secret note that an activation is dead (revoked by Dodo, or removed
/// by the user), kept outside the Keychain so it survives a restart even when
/// the Keychain refused to save or delete the record. Keyed by activation
/// (the instance id, hashed by the implementation); never holds the license
/// key, and never a time: the entry carries the record's `eventSeq` of the
/// revocation, so on load it is honored only while the saved record has not
/// caught up. Both writes report whether they were made durable; a read
/// that fails is a storage error, not an empty journal.
public protocol InvalidationJournal: Sendable {
    /// nil when there is no entry; throws when the journal cannot be read
    /// or the entry is unreadable.
    func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry?
    /// Written synchronously, before the record is touched, unless the
    /// journal already holds a readable newer entry (a later revocation is
    /// never downgraded). Replaces atomically: the new entry is durable and
    /// read back before anything older — readable or not — is retired, so
    /// a failure at any step leaves what was there. True when the journal
    /// now durably holds an entry with at least this sequence.
    func record(instanceID: String, entry: JournalEntry) -> Bool
    /// Removes a readable entry whose sequence is at most `seq` — a newer
    /// revocation survives an older clear, and an entry that cannot be read
    /// is never removed by a clear (false: nothing changed). True when the
    /// journal now durably holds no readable entry with a sequence up to `seq`.
    func clear(instanceID: String, upTo seq: UInt64) -> Bool
    /// Settles an entry that cannot be read with an authoritative answer:
    /// `entry` (a fresh revocation) or nil (Dodo said valid). Atomic like
    /// `record`: the replacement is durable before the unreadable data is
    /// retired. True when durable; no change when the entry is readable.
    func replaceUnreadable(instanceID: String, with entry: JournalEntry?) -> Bool
}

/// What the journal keeps per dead activation.
public struct JournalEntry: Codable, Equatable, Sendable {
    /// The record's `eventSeq` at the revocation or removal.
    public var seq: UInt64

    public init(seq: UInt64) {
        self.seq = seq
    }

    /// Entries written before the sequence existed (a revocation time): they
    /// are honored once against a record that has not caught up, and then
    /// rewritten in the current form.
    public static let legacy = JournalEntry(seq: 1)
}

/// An activation this Mac owes a deactivation for.
public struct PendingCleanup: Codable, Equatable, Sendable {
    public let licenseKey: String
    public let instanceID: String

    public init(licenseKey: String, instanceID: String) {
        self.licenseKey = licenseKey
        self.instanceID = instanceID
    }
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
    case removeFailedOffline
    case activated
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
        case .removeFailedOffline: "Couldn’t reach the license service to remove this Mac. Try again when you’re online."
        case .activated: "OpenReaction is licensed on this Mac."
        case .removed: "This Mac was removed from the license."
        case .storageFailed: "OpenReaction couldn’t save the license on this Mac (the Keychain refused). The activation was released; unlock the Keychain and try again."
        case .storageUnavailable: "OpenReaction can’t read or update its license in the Keychain right now. It keeps retrying; unlock the Keychain if it stays locked."
        case .cleanupPending: "A previous activation couldn’t be released yet; OpenReaction will retry. If a Mac stays counted, contact support."
        case .alreadyActivated: "This key is already active on this Mac."
        case .malformedResponse: "The license service sent an unexpected answer. Try again later."
        }
    }
}

/// Where licensing runs: its own serial executor, never the main actor, so
/// a Keychain or preferences call that stalls cannot stall the UI, the
/// deadline timers or the tap's shutdown.
@globalActor
public actor LicenseActor {
    public static let shared = LicenseActor()
}

/// Everything the app layer needs to know, captured by the manager right
/// after its memory changes and before it touches storage. The entitlement
/// is derived from the snapshot with the current clock (`state(now:)`), so
/// deadlines never wait on I/O.
public struct LicenseSnapshot: Equatable, Sendable {
    public var record: LicenseRecord?
    /// The license record was read (present or positively absent). Until
    /// then no trial runs: an unreadable record may hold a license.
    public var licenseRead: Bool
    /// The activation's journal entry is unreadable and Dodo has not settled it.
    public var isRestricted: Bool
    public var storageError: LicenseStoreError?
    public var journalError: Bool
    public var journalUnreadable: Bool
    /// The trial record as in memory; nil while it is absent or unread.
    public var trial: TrialRecord?
    /// The trial record could not be read or saved.
    public var trialStorageError: LicenseStoreError?
    public var trialTiming: TrialTiming
    /// When the app layer should call `tick` next (absolute, so a timer
    /// re-armed later from the same snapshot does not drift), if anything
    /// is scheduled.
    public var nextCheckAt: Date?
    public var nextDeadline: Date?
    public var hasPendingCleanups: Bool

    public init(
        record: LicenseRecord? = nil, licenseRead: Bool = false, isRestricted: Bool = false,
        storageError: LicenseStoreError? = nil, journalError: Bool = false, journalUnreadable: Bool = false,
        trial: TrialRecord? = nil, trialStorageError: LicenseStoreError? = nil, trialTiming: TrialTiming = .standard,
        nextCheckAt: Date? = nil, nextDeadline: Date? = nil, hasPendingCleanups: Bool = false
    ) {
        self.record = record
        self.licenseRead = licenseRead
        self.isRestricted = isRestricted
        self.storageError = storageError
        self.journalError = journalError
        self.journalUnreadable = journalUnreadable
        self.trial = trial
        self.trialStorageError = trialStorageError
        self.trialTiming = trialTiming
        self.nextCheckAt = nextCheckAt
        self.nextDeadline = nextDeadline
        self.hasPendingCleanups = hasPendingCleanups
    }

    /// A license always wins over the trial; without a readable license
    /// record the trial record decides.
    public func state(now: Date) -> LicenseState {
        if let record {
            let policy = LicensePolicy.state(record: record, now: now)
            if isRestricted, policy.isFeatureEnabled { return .checkRequired }
            return policy
        }
        guard licenseRead, let trial else { return .trialUnavailable }
        return LicensePolicy.trialState(trial, timing: trialTiming, now: now)
    }
}

/// The one place the app asks whether the core feature may run. A build with
/// licensing compiled out has no manager: everything is on and nothing is
/// ever called.
public enum LicenseGate {
    @LicenseActor
    public static func isFeatureEnabled(_ manager: LicenseManager?) -> Bool {
        manager?.isFeatureEnabled ?? true
    }
}
