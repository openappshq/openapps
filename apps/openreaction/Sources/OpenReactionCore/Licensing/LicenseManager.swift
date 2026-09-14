import Foundation

/// Runs the licensing rules from LICENSING.md against a store and a Dodo
/// client, with an injectable clock. Pure with respect to time and I/O; the
/// app layer owns timers, wake and network notifications and calls
/// `checkIfDue` / `check` at the right moments.
@MainActor
public final class LicenseManager {
    public static let activationName = "Mac"

    public let products: LicenseProducts
    private let client: any LicenseClient
    private let store: any LicenseStore
    private let now: () -> Date

    public private(set) var record: LicenseRecord?
    /// Dodo answered `valid: false` for the stored record.
    public private(set) var isRevoked = false
    /// Consecutive failed checks, for backoff.
    public private(set) var failedChecks = 0
    /// No calls before this moment (rate limit or backoff).
    public private(set) var blockedUntil: Date?
    public private(set) var isChecking = false
    /// Client calls made, for diagnostics and tests.
    public private(set) var callCount = 0

    public init(products: LicenseProducts, client: any LicenseClient, store: any LicenseStore, now: @escaping () -> Date = Date.init) {
        self.products = products
        self.client = client
        self.store = store
        self.now = now
        record = store.loadRecord()
    }

    // MARK: State

    public var state: LicenseState {
        LicensePolicy.state(record: record, revoked: isRevoked, now: now())
    }

    public var isFeatureEnabled: Bool { state.isFeatureEnabled }

    public var trialUsed: Bool { store.trialUsed }

    /// Whether a check should run now: due by the daily schedule (or clock
    /// rollback), not blocked by backoff or a rate limit, and not running.
    public var isCheckDue: Bool {
        guard let record, !isChecking else { return false }
        if let blockedUntil, now() < blockedUntil { return false }
        if failedChecks > 0 { return true }
        return LicensePolicy.isCheckDue(record: record, now: now())
    }

    /// When the app layer should call `checkIfDue` next, if nothing else
    /// (wake, network) prompts it earlier.
    public var nextCheckDelay: TimeInterval? {
        guard let record else { return nil }
        let current = now()
        if let blockedUntil, current < blockedUntil { return blockedUntil.timeIntervalSince(current) }
        if failedChecks > 0 { return LicensePolicy.retryDelay(afterFailures: failedChecks) }
        let due = record.lastSuccessAt.addingTimeInterval(LicensePolicy.checkInterval)
        return max(0, due.timeIntervalSince(current))
    }

    // MARK: Activation

    /// Activates `key` on this Mac. Refuses locally when a trial was already
    /// used here; otherwise calls Dodo and checks the product.
    public func activate(key rawKey: String) async -> LicenseMessage {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let blockedUntil, now() < blockedUntil {
            return .rateLimited(seconds: Int(blockedUntil.timeIntervalSince(now()).rounded(.up)))
        }
        callCount += 1
        switch await client.activate(licenseKey: key, name: Self.activationName) {
        case .keyNotFound:
            return .keyNotFound
        case .keyDisabledOrExpired:
            return .keyDisabledOrExpired
        case .activationLimitReached:
            return .allMacsActivated
        case .rateLimited(let retryAfter):
            block(for: retryAfter)
            return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
        case .unreachable:
            return .unreachable
        case .activated(let activation):
            guard let kind = products.kind(of: activation.productID) else {
                // Another app's key or the wrong environment: give the slot back.
                callCount += 1
                _ = await client.deactivate(licenseKey: key, instanceID: activation.instanceID)
                return .wrongProduct(productName: activation.productName)
            }
            if kind == .trial, store.trialUsed {
                // Should have been refused locally; never keep a second trial.
                callCount += 1
                _ = await client.deactivate(licenseKey: key, instanceID: activation.instanceID)
                return .trialAlreadyUsed
            }
            let previous = record
            let newRecord = LicenseRecord(
                licenseKey: key,
                instanceID: activation.instanceID,
                productID: activation.productID,
                kind: kind,
                activatedAt: activation.createdAt,
                lastSuccessAt: activation.serverDate ?? now()
            )
            if kind == .trial { store.markTrialUsed() }
            store.saveRecord(newRecord)
            record = newRecord
            isRevoked = false
            failedChecks = 0
            blockedUntil = nil
            if let previous, previous.kind == .trial, kind == .paid {
                // Buying during a trial: free the trial activation, best effort.
                callCount += 1
                _ = await client.deactivate(licenseKey: previous.licenseKey, instanceID: previous.instanceID)
            }
            return .activated(kind)
        }
    }

    /// True when a trial key must be refused without calling Dodo. The app
    /// cannot tell a trial key from a paid one before activation, so this is
    /// consulted when the user explicitly starts a trial.
    public var refusesTrialLocally: Bool { store.trialUsed }

    // MARK: Checks

    /// Runs the daily check if it is due. Returns whether a call was made.
    @discardableResult
    public func checkIfDue() async -> Bool {
        guard isCheckDue else { return false }
        await check()
        return true
    }

    /// Validates the stored activation now. A network failure never makes
    /// the state worse; only `valid: false` revokes.
    public func check() async {
        guard let record, !isChecking else { return }
        if let blockedUntil, now() < blockedUntil { return }
        isChecking = true
        defer { isChecking = false }
        callCount += 1
        switch await client.validate(licenseKey: record.licenseKey, instanceID: record.instanceID) {
        case .valid(let serverDate):
            var updated = record
            updated.lastSuccessAt = serverDate ?? now()
            store.saveRecord(updated)
            self.record = updated
            isRevoked = false
            failedChecks = 0
            blockedUntil = nil
        case .invalid:
            isRevoked = true
            failedChecks = 0
            blockedUntil = nil
        case .rateLimited(let retryAfter):
            block(for: retryAfter)
        case .unreachable:
            failedChecks += 1
            blockedUntil = now().addingTimeInterval(LicensePolicy.retryDelay(afterFailures: failedChecks))
        }
    }

    // MARK: Removal

    /// "Remove this Mac": deactivates, then clears the record (trial_used stays).
    public func removeThisMac() async -> LicenseMessage {
        guard let record else { return .removed }
        callCount += 1
        switch await client.deactivate(licenseKey: record.licenseKey, instanceID: record.instanceID) {
        case .deactivated:
            store.clearRecord()
            self.record = nil
            isRevoked = false
            failedChecks = 0
            blockedUntil = nil
            return .removed
        case .rateLimited(let retryAfter):
            block(for: retryAfter)
            return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
        case .unreachable:
            return .removeFailedOffline
        }
    }

    /// After `revoked`, the user may clear the dead record to start over.
    public func forgetRevokedRecord() {
        guard isRevoked else { return }
        store.clearRecord()
        record = nil
        isRevoked = false
    }

    private func block(for seconds: TimeInterval) {
        blockedUntil = now().addingTimeInterval(max(1, seconds))
    }
}
