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
    /// At launch or wake the clock was more than an hour behind
    /// `last_seen_at`: "Your Mac's clock is behind. Set the correct date and
    /// time to keep using your free trial". Lifts once the clock is back
    /// within the hour; the trial is not ended and gains no time.
    case trialClockBehind
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
        case .trialUnavailable, .trialNeedsConnection, .trialClockBehind, .trialEnded, .checkRequired, .revoked: false
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

    /// Derives the trial's state from its record and its clock projected to
    /// `observation`: ended at `duration` of elapsed time; off while a clock
    /// found behind at launch or wake still is; and an unregistered trial
    /// stops at its offline limit until the registry answers.
    public static func trialState(_ trial: TrialRecord, clock: TrialClock, timing: TrialTiming, at observation: TrialObservation) -> LicenseState {
        let elapsed = max(0, clock.projectedSeen(at: observation).timeIntervalSince(trial.startedAt))
        if elapsed >= timing.duration { return .trialEnded }
        if clock.isBehind(at: observation) { return .trialClockBehind }
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

    /// Seconds until the trial's state may change: on the projected trial
    /// clock (which moves with monotonic time), the next day boundary (days
    /// left, the offline limit) or the end; while the clock is behind, until
    /// the wall clock would be back within the hour.
    public static func trialDeadlineDelay(_ trial: TrialRecord, clock: TrialClock, timing: TrialTiming, at observation: TrialObservation) -> TimeInterval? {
        if clock.isBehind(at: observation) {
            // Held behind: nothing changes until the manager observes the
            // corrected clock. Wake when it would be within the hour, and keep
            // asking every minute once it is.
            let untilWithin = clock.seen.addingTimeInterval(-TrialClock.tolerance).timeIntervalSince(observation.wall)
            return untilWithin > 0 ? untilWithin : LicensePolicy.minimumRetryDelay
        }
        let seen = clock.projectedSeen(at: observation)
        return (1...3).map { trial.startedAt.addingTimeInterval(Double($0) * timing.day) }
            .filter { $0 > seen }
            .min()
            .map { $0.timeIntervalSince(seen) }
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
    /// The record store cannot be read or written (a directory or file
    /// the app can't open); the reason, for the License screen.
    case unavailable(String)
    /// A record exists but could not be decoded.
    case corrupt
}

/// Where the record lives (an encrypted file in the app; memory in tests). Every
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
/// by the user), kept outside the record store so it survives a restart even
/// when the store refused to save or delete the record. Keyed by activation
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
        case .storageFailed: "OpenReaction couldn’t save the license on this Mac (its records folder refused the write). The activation was released; check that Application Support is writable and try again."
        case .storageUnavailable: "OpenReaction can’t read or update its license records right now. It keeps retrying; check that its Application Support folder is readable and writable."
        case .cleanupPending: "A previous activation couldn’t be released yet; OpenReaction will retry. If a Mac stays counted, contact support."
        case .alreadyActivated: "This key is already active on this Mac."
        case .malformedResponse: "The license service sent an unexpected answer. Try again later."
        }
    }
}

/// Where licensing runs: its own serial executor, never the main actor, so
/// a storage or preferences call that stalls cannot stall the UI, the
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
    /// The trial's clock at its last observation. Enforcement projects it
    /// to the current readings, so trial deadlines move with monotonic time
    /// even while the manager waits on storage or the network.
    public var trialClock: TrialClock?
    /// The trial record could not be read or saved.
    public var trialStorageError: LicenseStoreError?
    public var trialTiming: TrialTiming
    /// When the app layer should call `tick` next (absolute, so a timer
    /// re-armed later from the same snapshot does not drift), if anything
    /// is scheduled.
    public var nextCheckAt: Date?
    /// The paid license's next deadline on the wall clock.
    public var nextDeadline: Date?
    public var hasPendingCleanups: Bool
    /// The license and trial records were both positively absent at the
    /// first read (see `LicenseManager.freshInstall`); nil until known.
    public var freshInstall: Bool?

    public init(
        record: LicenseRecord? = nil, licenseRead: Bool = false, isRestricted: Bool = false,
        storageError: LicenseStoreError? = nil, journalError: Bool = false, journalUnreadable: Bool = false,
        trial: TrialRecord? = nil, trialClock: TrialClock? = nil, trialStorageError: LicenseStoreError? = nil,
        trialTiming: TrialTiming = .standard, nextCheckAt: Date? = nil, nextDeadline: Date? = nil, hasPendingCleanups: Bool = false,
        freshInstall: Bool? = nil
    ) {
        self.trialClock = trialClock
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
        self.freshInstall = freshInstall
    }

    /// A license always wins over the trial; without a readable license
    /// record the trial record and its clock, projected to `now` and
    /// `uptime` (the monotonic clock), decide. `wakeSince`: the monotonic
    /// time of a wake the manager has not checked yet — the clock-behind
    /// check is applied here too, so a wake restricts before any I/O.
    public func state(now: Date, uptime: TimeInterval, wakeSince: TimeInterval? = nil) -> LicenseState {
        if let record {
            let policy = LicensePolicy.state(record: record, now: now)
            if isRestricted, policy.isFeatureEnabled { return .checkRequired }
            return policy
        }
        let observation = TrialObservation(wall: now, mono: uptime)
        guard licenseRead, let trial, let clock = projectedClock(at: observation, wakeSince: wakeSince) else {
            return .trialUnavailable
        }
        return LicensePolicy.trialState(trial, clock: clock, timing: trialTiming, at: observation)
    }

    /// Seconds until the state may change on its own: the paid license's
    /// next deadline, or the trial's on its projected clock.
    public func deadlineDelay(now: Date, uptime: TimeInterval, wakeSince: TimeInterval? = nil) -> TimeInterval? {
        if record != nil { return nextDeadline.map { max(0, $0.timeIntervalSince(now)) } }
        let observation = TrialObservation(wall: now, mono: uptime)
        guard licenseRead, let trial, let clock = projectedClock(at: observation, wakeSince: wakeSince) else { return nil }
        return LicensePolicy.trialDeadlineDelay(trial, clock: clock, timing: trialTiming, at: observation)
    }

    /// The trial clock, with an unchecked wake observed on a copy.
    private func projectedClock(at observation: TrialObservation, wakeSince: TimeInterval?) -> TrialClock? {
        guard var clock = trialClock else { return nil }
        // An unchecked wake may only restrict: a clock already held behind is
        // never released here, only by the manager's own observation.
        if let wakeSince, !clock.behind, (clock.lastBehindCheck ?? -.infinity) < wakeSince {
            clock.observe(observation, checkingBehind: true)
        }
        return clock
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
