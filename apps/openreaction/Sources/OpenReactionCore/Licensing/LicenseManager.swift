import Foundation

/// Runs the licensing rules from LICENSING.md against a store and a Dodo
/// client, with an injectable clock. The app layer owns timers, wake and
/// network notifications and calls `checkOnLaunch` / `checkIfDue` /
/// `noteTime` at the right moments.
///
/// Every operation that may change the record runs through one serial queue
/// (`perform`), and every network answer is applied only if the record it
/// was about is still the current one (`generation`). A late validation can
/// therefore never overwrite a newer activation or undo a removal.
@MainActor
public final class LicenseManager {
    public static let activationName = "Mac"

    public let products: LicenseProducts
    private let client: any LicenseClient
    private let store: any LicenseStore
    private let now: () -> Date

    public private(set) var record: LicenseRecord?
    /// Storage could not be read at load; the license is unknown, not absent.
    public private(set) var storageError: LicenseStoreError?
    /// Consecutive failed checks, for backoff.
    public private(set) var failedChecks = 0
    /// No calls before this moment (rate limit or backoff).
    public private(set) var blockedUntil: Date?
    /// When the last check was attempted, successful or not.
    public private(set) var lastAttemptAt: Date?
    /// Client calls made, for diagnostics and tests.
    public private(set) var callCount = 0
    /// Activations that should have been freed but could not be yet.
    public private(set) var pendingCleanups: [(licenseKey: String, instanceID: String)] = []

    /// Bumped on every record change; answers for an older generation are dropped.
    private var generation = 0
    private var queue: Task<Void, Never>?
    private var trialUsedCache: Bool?

    public init(products: LicenseProducts, client: any LicenseClient, store: any LicenseStore, now: @escaping () -> Date = Date.init) {
        self.products = products
        self.client = client
        self.store = store
        self.now = now
        do {
            record = try store.loadRecord()
        } catch {
            storageError = error
        }
    }

    // MARK: State

    public var state: LicenseState {
        LicensePolicy.state(record: record, now: now())
    }

    public var isFeatureEnabled: Bool { state.isFeatureEnabled }

    public var trialUsed: Bool {
        if let trialUsedCache { return trialUsedCache }
        let used = (try? store.loadTrialUsed()) ?? false
        trialUsedCache = used
        return used
    }

    /// True when a trial key must be refused without calling Dodo.
    public var refusesTrialLocally: Bool { trialUsed }

    /// The next moment the state changes on its own (trial expiry, grace
    /// warning or end), independent of any network schedule.
    public var nextDeadline: Date? {
        LicensePolicy.nextDeadline(record: record, now: now())
    }

    /// Whether a check should be attempted now: a day since the last attempt
    /// (or never attempted, or a retry is due), not blocked, not running.
    public var isCheckDue: Bool {
        guard record != nil, !isChecking else { return false }
        let current = now()
        if let blockedUntil, current < blockedUntil { return false }
        guard let lastAttemptAt else { return true }
        if failedChecks > 0 && failedChecks <= LicensePolicy.maximumRetries {
            return current >= lastAttemptAt.addingTimeInterval(LicensePolicy.retryDelay(afterFailures: failedChecks))
        }
        // Rollback: the clock is before the last attempt; check again.
        return current >= lastAttemptAt.addingTimeInterval(LicensePolicy.checkInterval)
            || current < lastAttemptAt.addingTimeInterval(-LicensePolicy.clockRollbackTolerance)
    }

    /// When the app layer should call `checkIfDue` next, if nothing else
    /// (wake, network) prompts it earlier.
    public var nextCheckDelay: TimeInterval? {
        guard record != nil else { return nil }
        let current = now()
        if let blockedUntil, current < blockedUntil { return blockedUntil.timeIntervalSince(current) }
        guard let lastAttemptAt else { return 0 }
        let wait: TimeInterval
        if failedChecks > 0 && failedChecks <= LicensePolicy.maximumRetries {
            wait = LicensePolicy.retryDelay(afterFailures: failedChecks)
        } else {
            wait = LicensePolicy.checkInterval
        }
        return max(0, lastAttemptAt.addingTimeInterval(wait).timeIntervalSince(current))
    }

    public private(set) var isChecking = false

    // MARK: Serialization

    /// Runs `operation` after every earlier operation has finished.
    private func perform<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func commit(_ newRecord: LicenseRecord?) throws(LicenseStoreError) {
        if let newRecord {
            try store.saveRecord(newRecord)
        } else {
            try store.clearRecord()
        }
        record = newRecord
        generation += 1
    }

    // MARK: Activation

    /// Activates `key` on this Mac. `expecting` is the route the user took:
    /// `.trial` from the trial flow (refused locally when the trial was used
    /// here, without calling Dodo), `nil` from the plain key field.
    public func activate(key rawKey: String, expecting: LicenseKind? = nil) async -> LicenseMessage {
        await perform { await self.activateNow(key: rawKey, expecting: expecting) }
    }

    private func activateNow(key rawKey: String, expecting: LicenseKind?) async -> LicenseMessage {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if expecting == .trial, trialUsed {
            return .trialAlreadyUsed
        }
        if let blockedUntil, now() < blockedUntil {
            return .rateLimited(seconds: Int(blockedUntil.timeIntervalSince(now()).rounded(.up)))
        }
        // The same paid key again: keep the existing activation, just verify it.
        if let record, record.kind == .paid, record.licenseKey == key, !record.isRevoked {
            callCount += 1
            switch await client.validate(licenseKey: key, instanceID: record.instanceID) {
            case .valid(let serverDate):
                applySuccess(serverDate: serverDate, for: record)
                return .alreadyActivated
            case .rateLimited(let retryAfter):
                block(for: retryAfter)
                return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
            case .unreachable:
                return .unreachable
            case .invalid:
                break // Fall through: activate afresh.
            }
        }

        callCount += 1
        switch await client.activate(licenseKey: key, name: Self.activationName) {
        case .keyNotFound: return .keyNotFound
        case .keyDisabledOrExpired: return .keyDisabledOrExpired
        case .activationLimitReached: return .allMacsActivated
        case .rateLimited(let retryAfter):
            block(for: retryAfter)
            return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
        case .unreachable: return .unreachable
        case .activated(let activation):
            guard let kind = products.kind(of: activation.productID) else {
                // Another app's key or the wrong environment: give the slot back.
                await release(licenseKey: key, instanceID: activation.instanceID)
                return .wrongProduct(productName: activation.productName)
            }
            if kind == .trial, trialUsed {
                await release(licenseKey: key, instanceID: activation.instanceID)
                return .trialAlreadyUsed
            }
            let previous = record
            let observed = max(activation.serverDate ?? now(), activation.createdAt)
            let newRecord = LicenseRecord(
                licenseKey: key, instanceID: activation.instanceID, productID: activation.productID, kind: kind,
                activatedAt: activation.createdAt, lastSuccessAt: activation.serverDate ?? now(), lastObservedAt: observed
            )
            // Persist first; announce success only once the record is durable.
            do {
                try commit(newRecord)
                if kind == .trial {
                    do {
                        try store.markTrialUsed()
                        trialUsedCache = true
                    } catch {
                        // Never keep a trial that could be taken again later.
                        try? commit(previous)
                        throw error
                    }
                }
            } catch {
                await release(licenseKey: key, instanceID: activation.instanceID)
                return .storageFailed
            }
            failedChecks = 0
            blockedUntil = nil
            lastAttemptAt = now()
            if let previous, previous.instanceID != activation.instanceID {
                // A trial replaced by a purchase, or a different paid key:
                // free the old activation so it does not count against the limit.
                await release(licenseKey: previous.licenseKey, instanceID: previous.instanceID)
            }
            return pendingCleanups.isEmpty ? .activated(kind) : .cleanupPending
        }
    }

    /// Deactivates an activation we must not keep; remembers it for retry
    /// if Dodo could not be reached.
    private func release(licenseKey: String, instanceID: String) async {
        callCount += 1
        switch await client.deactivate(licenseKey: licenseKey, instanceID: instanceID) {
        case .deactivated:
            pendingCleanups.removeAll { $0.instanceID == instanceID }
        case .rateLimited(let retryAfter):
            block(for: retryAfter)
            remember(licenseKey: licenseKey, instanceID: instanceID)
        case .unreachable:
            remember(licenseKey: licenseKey, instanceID: instanceID)
        }
    }

    private func remember(licenseKey: String, instanceID: String) {
        guard !pendingCleanups.contains(where: { $0.instanceID == instanceID }) else { return }
        pendingCleanups.append((licenseKey, instanceID))
    }

    /// Retries deactivations that could not be completed earlier.
    public func retryPendingCleanups() async {
        await perform {
            for cleanup in self.pendingCleanups {
                if let blockedUntil = self.blockedUntil, self.now() < blockedUntil { return }
                await self.release(licenseKey: cleanup.licenseKey, instanceID: cleanup.instanceID)
            }
        }
    }

    // MARK: Checks

    /// The launch check: always attempted in the background, subject only to
    /// an active rate limit.
    public func checkOnLaunch() async {
        await perform { await self.checkNow() }
    }

    /// Runs the daily check if it is due. Returns whether a call was made.
    @discardableResult
    public func checkIfDue() async -> Bool {
        await perform {
            guard self.isCheckDue else { return false }
            await self.checkNow()
            return true
        }
    }

    /// Validates the stored activation now. A network failure never makes
    /// the state worse; only `valid: false` revokes, and only for the record
    /// the answer was about.
    public func check() async {
        await perform { await self.checkNow() }
    }

    private func checkNow() async {
        guard let record else { return }
        if let blockedUntil, now() < blockedUntil { return }
        isChecking = true
        defer { isChecking = false }
        let expected = generation
        lastAttemptAt = now()
        callCount += 1
        let result = await client.validate(licenseKey: record.licenseKey, instanceID: record.instanceID)
        guard generation == expected, let current = self.record, current.instanceID == record.instanceID else {
            return // The record changed meanwhile; this answer is about the old one.
        }
        switch result {
        case .valid(let serverDate):
            applySuccess(serverDate: serverDate, for: current)
        case .invalid:
            var revoked = current
            revoked.revokedAt = now()
            try? commit(revoked)
            failedChecks = 0
            blockedUntil = nil
        case .rateLimited(let retryAfter):
            // A failed attempt too: retry once the limit lifts.
            failedChecks += 1
            block(for: retryAfter)
        case .unreachable:
            failedChecks += 1
        }
    }

    private func applySuccess(serverDate: Date?, for current: LicenseRecord) {
        var updated = current
        let successAt = serverDate ?? now()
        updated.lastSuccessAt = successAt
        updated.revokedAt = nil
        updated.lastObservedAt = max(updated.lastObservedAt, successAt, now())
        // Storage failure here only loses the fresher timestamp; keep it in memory.
        do { try commit(updated) } catch { record = updated; generation += 1 }
        failedChecks = 0
        blockedUntil = nil
    }

    /// Records that time has moved on, so a later clock rollback cannot
    /// extend a trial or grace. Cheap; the app calls it on its local timers.
    public func noteTime() {
        guard let record else { return }
        let current = now()
        guard current > record.lastObservedAt.addingTimeInterval(60) else { return }
        var updated = record
        updated.lastObservedAt = current
        do { try commit(updated) } catch { self.record = updated }
    }

    // MARK: Removal

    /// "Remove this Mac": deactivates, then clears the record (trial_used stays).
    public func removeThisMac() async -> LicenseMessage {
        await perform {
            guard let record = self.record else { return .removed }
            if let blockedUntil = self.blockedUntil, self.now() < blockedUntil {
                return .rateLimited(seconds: Int(blockedUntil.timeIntervalSince(self.now()).rounded(.up)))
            }
            self.callCount += 1
            switch await self.client.deactivate(licenseKey: record.licenseKey, instanceID: record.instanceID) {
            case .deactivated:
                do { try self.commit(nil) } catch { return .storageFailed }
                self.failedChecks = 0
                self.blockedUntil = nil
                self.lastAttemptAt = nil
                return .removed
            case .rateLimited(let retryAfter):
                self.block(for: retryAfter)
                return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
            case .unreachable:
                return .removeFailedOffline
            }
        }
    }

    /// After `revoked`, the user may clear the dead record to start over.
    public func forgetRevokedRecord() {
        guard let record, record.isRevoked else { return }
        try? commit(nil)
        lastAttemptAt = nil
    }

    private func block(for seconds: TimeInterval) {
        let bounded = seconds.isFinite ? min(max(1, seconds), 86_400) : 60
        blockedUntil = now().addingTimeInterval(bounded)
    }
}
