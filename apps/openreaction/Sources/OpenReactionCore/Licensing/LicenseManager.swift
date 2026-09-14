import Foundation

/// Runs the licensing rules from LICENSING.md against a store and a Dodo
/// client, with an injectable clock. The app layer owns timers, wake and
/// network notifications and calls `checkOnLaunch` / `tick` at the right
/// moments.
///
/// Every operation that may change the record runs through one serial queue
/// (`perform`). The *activation* is identified by `activationGeneration`,
/// which changes only when an activation is created, replaced or removed; a
/// network answer is applied only to the activation it was about. Time
/// metadata never changes the generation.
///
/// Invalidation (`valid: false`) and removal are journaled outside the
/// Keychain first, then take effect in memory at once; if the Keychain
/// refuses the write it is retried on every tick and surfaced as a storage
/// problem, and the journal entry keeps the activation dead across a restart
/// until the record is durably saved as revoked, deleted or replaced. Nothing
/// ever re-enables an invalidated activation except a successful check of
/// that same activation or a successful new activation.
@MainActor
public final class LicenseManager {
    public static let activationName = "Mac"
    /// How often pending cleanups and durable writes are retried.
    public static let cleanupRetryInterval: TimeInterval = 5 * 60

    public let products: LicenseProducts
    private let client: any LicenseClient
    private let store: any LicenseStore
    private let journal: any InvalidationJournal
    private let now: () -> Date

    public private(set) var record: LicenseRecord?
    /// The record as it should be on disk while the last write has failed.
    private var pendingDurableWrite: LicenseRecord??
    /// The cleanups list on disk is behind memory.
    private var cleanupsDirty = false
    /// The cleanups on disk could not be read; nothing may overwrite them
    /// until they were merged in.
    private var cleanupsUnread = false
    /// A journal write the journal has not accepted yet, one per activation:
    /// a newer operation supersedes an older one. Retried on ticks.
    private enum JournalOp: Equatable {
        case record(seq: UInt64)
        case clear(upTo: UInt64)

        var seq: UInt64 {
            switch self {
            case .record(let seq), .clear(let seq): seq
            }
        }
    }
    private var pendingJournalOps: [String: JournalOp] = [:]
    /// Activations known to have a journal entry (written here or found on
    /// load), with the highest sequence known to be in it.
    private var journaledSeq: [String: UInt64] = [:]
    /// The instance whose record is being deleted, with its tombstone's
    /// sequence; the entry goes once the deletion is durable, or once a new
    /// record durably replaces it.
    private var removingInstance: (instanceID: String, seq: UInt64)?
    /// The journal could not be written; surfaced like a storage problem.
    public private(set) var journalError = false
    /// The journal could not be read: the core stays off until it can be,
    /// and nothing overwrites it meanwhile.
    public private(set) var journalUnreadable = false
    /// Storage could not be read or written; retried on every tick.
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
    public private(set) var pendingCleanups: [PendingCleanup] = []
    public private(set) var isChecking = false

    /// Identity of the current activation; answers about an older one are dropped.
    private var activationGeneration = 0
    private var queue: Task<Void, Never>?

    public init(
        products: LicenseProducts, client: any LicenseClient, store: any LicenseStore,
        journal: any InvalidationJournal, now: @escaping () -> Date = Date.init
    ) {
        self.products = products
        self.client = client
        self.store = store
        self.journal = journal
        self.now = now
        reloadFromStore()
    }

    /// Reads what the store has. A journal entry for the stored activation
    /// wins over the record while the saved record has not caught up with it
    /// (`entry.seq > record.eventSeq`): the record is revoked in memory, at
    /// that sequence, and its save owed. An entry the record has caught up
    /// with is stale and goes away. A journal that cannot be read keeps the
    /// core off and is left alone.
    private func reloadFromStore() {
        var failure: LicenseStoreError?
        do {
            var loaded = try store.loadRecord()
            if var current = loaded {
                do {
                    journalUnreadable = false
                    if let entry = try journal.entry(instanceID: current.instanceID) {
                        if entry.seq > current.eventSeq {
                            journaledSeq[current.instanceID] = entry.seq
                            if entry == .legacy { journalRecord(current.instanceID, entry: entry) } // rewrite in the current form
                            current.revokedAt = current.revokedAt ?? now()
                            current.eventSeq = entry.seq
                            loaded = current
                            pendingDurableWrite = .some(current)
                        } else {
                            clearJournal(current.instanceID, upTo: current.eventSeq)
                        }
                    }
                } catch {
                    journalUnreadable = true
                    failure = error
                }
            }
            record = loaded
        } catch {
            failure = error
        }
        do {
            let stored = try store.loadPendingCleanups()
            pendingCleanups = Self.merged(pendingCleanups, stored)
            cleanupsUnread = false
        } catch {
            cleanupsUnread = true
            failure = failure ?? error
        }
        storageError = failure
        flushRecord()
    }

    /// Union by activation, keeping order: what was already known first.
    private static func merged(_ known: [PendingCleanup], _ stored: [PendingCleanup]) -> [PendingCleanup] {
        known + stored.filter { candidate in !known.contains { $0.instanceID == candidate.instanceID } }
    }

    /// Whether memory holds something the store or journal has not accepted
    /// yet, or the store holds cleanups memory has not seen.
    private var owesDurableWrite: Bool {
        pendingDurableWrite != nil || cleanupsDirty || cleanupsUnread || !pendingJournalOps.isEmpty
    }

    // MARK: State

    public var state: LicenseState {
        let policy = LicensePolicy.state(record: record, now: now())
        // The journal may say this activation is dead; until it can be read,
        // or Dodo answers, nothing local is trusted.
        if journalUnreadable, record != nil, policy.isFeatureEnabled { return .checkRequired }
        return policy
    }

    public var isFeatureEnabled: Bool { state.isFeatureEnabled }

    /// Fails closed: if the marker cannot be read, a trial is refused.
    public var trialUsed: Bool {
        readTrialUsed() ?? true
    }

    /// nil when the marker cannot be read.
    private func readTrialUsed() -> Bool? {
        try? store.loadTrialUsed()
    }

    /// The next moment the state changes on its own (trial expiry, grace
    /// warning or end), independent of any network schedule.
    public var nextDeadline: Date? {
        LicensePolicy.nextDeadline(record: record, now: now())
    }

    /// Whether a check should be attempted now: a day since the last attempt
    /// (or never attempted, a retry due, or the clock went back since the
    /// last attempt), not blocked, not running.
    public var isCheckDue: Bool {
        guard record != nil, !isChecking else { return false }
        let current = now()
        if let blockedUntil, current < blockedUntil { return false }
        guard let lastAttemptAt else { return true }
        // Only Dodo can settle what an unreadable journal may say.
        if journalUnreadable, failedChecks == 0 { return true }
        if current < lastAttemptAt.addingTimeInterval(-LicensePolicy.clockRollbackTolerance) { return true }
        return current >= lastAttemptAt.addingTimeInterval(scheduledWait)
    }

    /// The wait after the last attempt: backoff while retries remain, else a day.
    private var scheduledWait: TimeInterval {
        failedChecks > 0 && failedChecks <= LicensePolicy.maximumRetries
            ? LicensePolicy.retryDelay(afterFailures: failedChecks)
            : LicensePolicy.checkInterval
    }

    /// When the app layer should call `tick` next, if nothing else (wake,
    /// network) prompts it earlier. Pending cleanups and durable writes keep
    /// a schedule alive even without a license.
    public var nextCheckDelay: TimeInterval? {
        let current = now()
        var candidates: [TimeInterval] = []
        if record != nil {
            if let blockedUntil, current < blockedUntil {
                candidates.append(blockedUntil.timeIntervalSince(current))
            } else if let lastAttemptAt {
                if current < lastAttemptAt.addingTimeInterval(-LicensePolicy.clockRollbackTolerance) {
                    candidates.append(0)
                } else {
                    candidates.append(max(0, lastAttemptAt.addingTimeInterval(scheduledWait).timeIntervalSince(current)))
                }
            } else {
                candidates.append(0)
            }
        }
        if !pendingCleanups.isEmpty || owesDurableWrite || storageError != nil || journalError {
            if let blockedUntil, current < blockedUntil {
                candidates.append(blockedUntil.timeIntervalSince(current))
            } else {
                candidates.append(Self.cleanupRetryInterval)
            }
        }
        return candidates.min()
    }

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

    /// Updates the record in memory first, then on disk. A failed write is
    /// remembered and retried; it never undoes the in-memory change.
    private func write(_ newRecord: LicenseRecord?) {
        record = newRecord
        pendingDurableWrite = .some(newRecord)
        flushRecord()
    }

    private func flushRecord() {
        guard let pending = pendingDurableWrite else { return }
        do {
            if let pending { try store.saveRecord(pending) } else { try store.clearRecord() }
            pendingDurableWrite = nil
            // Durable now: a revoked record carries its own revocation, and a
            // deleted one is gone.
            // The saved record has caught up with any entry up to its sequence.
            if let pending, let known = journaledSeq[pending.instanceID], known <= pending.eventSeq {
                clearJournal(pending.instanceID, upTo: pending.eventSeq)
            }
            if pending == nil, let removed = removingInstance {
                removingInstance = nil
                clearJournal(removed.instanceID, upTo: removed.seq)
            }
            if !cleanupsDirty, !cleanupsUnread, !journalUnreadable { storageError = nil }
        } catch {
            storageError = error
        }
    }

    /// Journals a dead activation before anything else is touched. A failed
    /// write keeps the in-memory lock, is retried on ticks and reported.
    private func journalRecord(_ instanceID: String, entry: JournalEntry) {
        journaledSeq[instanceID] = max(journaledSeq[instanceID] ?? 0, entry.seq)
        apply(.record(seq: entry.seq), to: instanceID)
    }

    /// Removes a journal entry up to `seq`; retried on ticks until it is
    /// really gone. A newer entry for the activation is never touched.
    private func clearJournal(_ instanceID: String, upTo seq: UInt64) {
        apply(.clear(upTo: seq), to: instanceID)
    }

    /// Runs one journal operation now; if the journal refuses it, keeps it
    /// for the next tick — unless a newer operation for that activation is
    /// already waiting, which supersedes it.
    private func apply(_ op: JournalOp, to instanceID: String) {
        if let waiting = pendingJournalOps[instanceID], waiting.seq > op.seq {
            journalError = true
            return
        }
        let done: Bool
        switch op {
        case .record(let seq): done = journal.record(instanceID: instanceID, entry: JournalEntry(seq: seq))
        case .clear(let upTo): done = journal.clear(instanceID: instanceID, upTo: upTo)
        }
        if done {
            pendingJournalOps[instanceID] = nil
            if case .clear(let upTo) = op, let known = journaledSeq[instanceID], known <= upTo {
                journaledSeq[instanceID] = nil // gone; a newer entry would have survived
            }
        } else {
            pendingJournalOps[instanceID] = op
        }
        journalError = !pendingJournalOps.isEmpty
    }

    private func retryJournal() {
        for (instanceID, op) in pendingJournalOps { apply(op, to: instanceID) }
    }

    /// Writes the cleanups, first merging in whatever the store holds if it
    /// could not be read before; an unreadable store is never overwritten.
    private func flushCleanups() {
        guard cleanupsDirty else { return }
        if cleanupsUnread {
            do {
                pendingCleanups = Self.merged(pendingCleanups, try store.loadPendingCleanups())
                cleanupsUnread = false
            } catch .corrupt {
                cleanupsUnread = false // nothing recoverable there; replace it
            } catch {
                storageError = error
                return
            }
        }
        do {
            try store.savePendingCleanups(pendingCleanups)
            cleanupsDirty = false
            if pendingDurableWrite == nil, !journalUnreadable { storageError = nil }
        } catch {
            storageError = error
        }
    }

    /// Retries whatever the store or journal refused; with no write owed, a
    /// store that could not be read is read again (merging in unread cleanups).
    private func retryStorage() {
        retryJournal()
        guard pendingDurableWrite != nil || cleanupsDirty else {
            if storageError != nil || journalUnreadable { reloadFromStore() }
            return
        }
        flushRecord()
        flushCleanups()
    }

    /// A removed activation: answers about the old one are stale. The
    /// activation is journaled dead first; the entry goes once the record's
    /// deletion is durable.
    private func removeActivation() {
        activationGeneration += 1
        if let previous = record {
            journalRecord(previous.instanceID, entry: JournalEntry(seq: previous.eventSeq + 1))
            removingInstance = (previous.instanceID, previous.eventSeq + 1)
        }
        write(nil)
    }

    /// A new activation whose record the store already holds: the previous
    /// activation's record — and one whose deletion was still owed — is
    /// durably replaced, so their journal entries go.
    private func commitActivation(_ newRecord: LicenseRecord) {
        activationGeneration += 1
        // The replaced activation is dead for good: any entry about it goes.
        if let previous = record, previous.instanceID != newRecord.instanceID, journaledSeq[previous.instanceID] != nil {
            clearJournal(previous.instanceID, upTo: .max)
        }
        if let removing = removingInstance, removing.instanceID != newRecord.instanceID {
            removingInstance = nil
            clearJournal(removing.instanceID, upTo: .max)
        }
        record = newRecord
        pendingDurableWrite = nil
        if !cleanupsDirty, !cleanupsUnread { storageError = nil }
        failedChecks = 0
        blockedUntil = nil
        lastAttemptAt = now()
    }

    /// Invalidation takes effect immediately, whatever storage says: the
    /// journal is written first, so a restart before the Keychain accepts
    /// the revoked record still finds it revoked.
    private func invalidate(_ current: LicenseRecord) {
        var revoked = current
        revoked.revokedAt = now()
        revoked.eventSeq = current.eventSeq + 1
        if journalUnreadable {
            // Dodo's answer supersedes whatever the unreadable entry said.
            clearJournal(current.instanceID, upTo: .max)
            journalUnreadable = pendingJournalOps[current.instanceID] != nil
        }
        journalRecord(current.instanceID, entry: JournalEntry(seq: revoked.eventSeq))
        write(revoked)
        failedChecks = 0
        blockedUntil = nil
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
        if expecting == .trial {
            guard let used = readTrialUsed() else { return .storageUnavailable }
            if used { return .trialAlreadyUsed }
        }
        if let blockedUntil, now() < blockedUntil {
            return .rateLimited(seconds: Int(blockedUntil.timeIntervalSince(now()).rounded(.up)))
        }
        // The same paid key on a live activation: keep it, just verify it.
        if let record, record.kind == .paid, record.licenseKey == key, !record.isRevoked {
            callCount += 1
            lastAttemptAt = now()
            switch await client.validate(licenseKey: key, instanceID: record.instanceID) {
            case .valid(let serverDate):
                if let current = self.record, current.instanceID == record.instanceID { applySuccess(serverDate: serverDate, for: current) }
                return .alreadyActivated
            case .rateLimited(let retryAfter):
                block(for: retryAfter)
                return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
            case .unreachable:
                return .unreachable
            case .invalid:
                // Authoritative: this activation is dead. Show that; the user
                // may activate again explicitly.
                if let current = self.record, current.instanceID == record.instanceID { invalidate(current) }
                return .keyDisabledOrExpired
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
        case .malformed: return .malformedResponse
        case .activated(let activation):
            guard let instanceID = Self.identifier(activation.instanceID),
                  let productID = Self.identifier(activation.productID) else { return .malformedResponse }
            guard let kind = products.kind(of: productID) else {
                // Another app's key or the wrong environment: give the slot back.
                await release(licenseKey: key, instanceID: instanceID)
                return .wrongProduct(productName: activation.productName)
            }
            if kind == .trial {
                // Never a second trial on this Mac; unreadable storage counts as used.
                guard let used = readTrialUsed() else {
                    await release(licenseKey: key, instanceID: instanceID)
                    return .storageUnavailable
                }
                if used {
                    await release(licenseKey: key, instanceID: instanceID)
                    return .trialAlreadyUsed
                }
            }
            let previous = record
            let anchor = activation.serverDate ?? now()
            let newRecord = LicenseRecord(
                licenseKey: key, instanceID: instanceID, productID: productID, kind: kind,
                activatedAt: activation.createdAt, lastSuccessAt: anchor, lastObservedAt: max(anchor, activation.createdAt)
            )
            // Persist first; announce success only once the record is durable.
            if let failure = persist(newRecord, markingTrial: kind == .trial, previous: previous) {
                storageError = failure
                await release(licenseKey: key, instanceID: instanceID)
                return .storageFailed
            }
            commitActivation(newRecord)
            if let previous, previous.instanceID != instanceID {
                // A trial replaced by a purchase, or a different paid key:
                // free the old activation so it does not count against the limit.
                await release(licenseKey: previous.licenseKey, instanceID: previous.instanceID)
            }
            return pendingCleanups.isEmpty ? .activated(kind) : .cleanupPending
        }
    }

    /// A usable id from a response field: trimmed, non-empty, no control
    /// characters (newlines included). Anything else is malformed.
    private static func identifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return trimmed
    }

    /// Saves a new record and, for a trial, the used marker. Returns the
    /// failure, having restored the previous record if the marker failed so
    /// no trial can be taken twice.
    private func persist(_ newRecord: LicenseRecord, markingTrial: Bool, previous: LicenseRecord?) -> LicenseStoreError? {
        do {
            try store.saveRecord(newRecord)
        } catch {
            return error
        }
        guard markingTrial else { return nil }
        do {
            try store.markTrialUsed()
            return nil
        } catch {
            if let previous { try? store.saveRecord(previous) } else { try? store.clearRecord() }
            return error
        }
    }

    /// Deactivates an activation we must not keep; remembers it (durably)
    /// for retry if Dodo could not be reached.
    private func release(licenseKey: String, instanceID: String) async {
        callCount += 1
        switch await client.deactivate(licenseKey: licenseKey, instanceID: instanceID) {
        case .deactivated:
            setPendingCleanups(pendingCleanups.filter { $0.instanceID != instanceID })
        case .rateLimited(let retryAfter):
            block(for: retryAfter)
            remember(licenseKey: licenseKey, instanceID: instanceID)
        case .unreachable:
            remember(licenseKey: licenseKey, instanceID: instanceID)
        }
    }

    private func remember(licenseKey: String, instanceID: String) {
        guard !pendingCleanups.contains(where: { $0.instanceID == instanceID }) else { return }
        setPendingCleanups(pendingCleanups + [PendingCleanup(licenseKey: licenseKey, instanceID: instanceID)])
    }

    private func setPendingCleanups(_ cleanups: [PendingCleanup]) {
        guard cleanups != pendingCleanups else { return }
        pendingCleanups = cleanups
        cleanupsDirty = true
        flushCleanups()
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

    /// Validates the stored activation now.
    public func check() async {
        await perform { await self.checkNow() }
    }

    /// Housekeeping the app layer runs on every timer, wake and network event:
    /// records that time passed, retries failed writes and cleanups, then
    /// runs the check if it is due.
    public func tick() async {
        await perform {
            self.retryStorage()
            self.noteTime()
            await self.retryCleanupsNow()
            if self.isCheckDue { await self.checkNow() }
        }
    }

    private func checkNow() async {
        guard let record else { return }
        if let blockedUntil, now() < blockedUntil { return }
        isChecking = true
        defer { isChecking = false }
        let expected = activationGeneration
        lastAttemptAt = now()
        callCount += 1
        let result = await client.validate(licenseKey: record.licenseKey, instanceID: record.instanceID)
        guard activationGeneration == expected, let current = self.record, current.instanceID == record.instanceID else {
            return // The activation changed meanwhile; this answer is about the old one.
        }
        switch result {
        case .valid(let serverDate):
            applySuccess(serverDate: serverDate, for: current)
        case .invalid:
            invalidate(current)
        case .rateLimited(let retryAfter):
            failedChecks += 1
            block(for: retryAfter)
        case .unreachable:
            failedChecks += 1
        }
    }

    /// A successful check: fresh success time, revocation cleared, and time
    /// re-anchored from the server when it says what time it is.
    private func applySuccess(serverDate: Date?, for current: LicenseRecord) {
        var updated = current
        let successAt = serverDate ?? now()
        updated.lastSuccessAt = successAt
        updated.revokedAt = nil
        updated.lastObservedAt = serverDate.map { max($0, current.activatedAt) } ?? max(current.lastObservedAt, now())
        // An authoritative grant: the record moves past any journal entry,
        // which goes once this record is durable (`flushRecord`). If the
        // save fails, a restart stays locked until the next successful check.
        updated.eventSeq = current.eventSeq + 1
        if journalUnreadable {
            // Dodo settled what the unreadable entry might have said: rebuild
            // the journal without it.
            journaledSeq[current.instanceID] = .max
            clearJournal(current.instanceID, upTo: .max)
            journalUnreadable = pendingJournalOps[current.instanceID] != nil
        }
        write(updated)
        failedChecks = 0
        blockedUntil = nil
    }

    /// Time moved on: remember it so a later rollback is detected. Never
    /// touches the activation identity.
    private func noteTime() {
        guard let record else { return }
        let current = now()
        guard current > record.lastObservedAt.addingTimeInterval(60) else { return }
        var updated = record
        updated.lastObservedAt = current
        write(updated)
    }

    private func retryCleanupsNow() async {
        for cleanup in pendingCleanups {
            if let blockedUntil, now() < blockedUntil { return }
            await release(licenseKey: cleanup.licenseKey, instanceID: cleanup.instanceID)
        }
    }

    /// Retries deactivations that could not be completed earlier.
    public func retryPendingCleanups() async {
        await perform { await self.retryCleanupsNow() }
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
                self.removeActivation()
                self.failedChecks = 0
                self.blockedUntil = nil
                self.lastAttemptAt = nil
                return self.storageError == nil && !self.journalError ? .removed : .storageUnavailable
            case .rateLimited(let retryAfter):
                self.block(for: retryAfter)
                return .rateLimited(seconds: Int(retryAfter.rounded(.up)))
            case .unreachable:
                return .removeFailedOffline
            }
        }
    }

    private func block(for seconds: TimeInterval) {
        let bounded = seconds.isFinite ? min(max(1, seconds), 86_400) : 60
        blockedUntil = now().addingTimeInterval(bounded)
    }
}
