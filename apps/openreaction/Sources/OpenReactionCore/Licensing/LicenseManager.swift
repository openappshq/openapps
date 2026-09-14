import Foundation

/// Runs the licensing rules from LICENSING.md against a store and a Dodo
/// client, and the in-app trial against a trial store and the trial
/// registry, with an injectable clock. The app layer owns timers, wake and
/// network notifications and calls `checkOnLaunch` / `tick` at the right
/// moments.
///
/// A license always wins over the trial. Without a license record the trial
/// record decides: a Mac whose trial record is positively absent starts a
/// provisional trial (saved before the core turns on) and registers it in
/// the background; the registry's answer can only move the start earlier.
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
@LicenseActor
public final class LicenseManager {
    public static let activationName = "Mac"
    /// How often pending cleanups and durable writes are retried.
    public static let cleanupRetryInterval: TimeInterval = 5 * 60

    /// The app id the trial registry and the device hash use.
    public nonisolated static let trialAppID = "openreaction"

    public let products: LicenseProducts
    public nonisolated let trialTiming: TrialTiming
    private let client: any LicenseClient
    private let store: any LicenseStore
    private let journal: any InvalidationJournal
    private let trialStore: any TrialStore
    private let registry: any TrialRegistryClient
    private let device: any DeviceIdentity
    private let now: @Sendable () -> Date

    public private(set) var record: LicenseRecord?
    /// The license record was read, present or positively absent. No trial
    /// starts or runs before that.
    public private(set) var licenseRead = false

    // MARK: Trial state

    /// The trial record in memory; nil while absent or unread.
    public private(set) var trial: TrialRecord?
    private enum TrialLoad { case unread, absent, present }
    private var trialLoad: TrialLoad = .unread
    /// The trial record could not be read or saved; retried on ticks.
    public private(set) var trialStorageError: LicenseStoreError?
    /// Memory holds trial data the store does not have yet.
    private var trialDirty = false
    /// That data must be saved on the next tick (not only hourly): a
    /// registry answer, a fallback device id, the end, or a failed save.
    private var trialSaveRequired = false
    private var lastTrialSaveAt: Date?
    /// The ended trial's `last_seen_at` has been saved in this process.
    private var trialEndSaved = false
    /// Identity of the trial record in memory; a registry answer applies
    /// only to the record it was asked for.
    private var trialGeneration = 0
    /// Consecutive failed registry calls, for backoff.
    public private(set) var registryFailures = 0
    /// No registry call before this moment (`Retry-After`).
    public private(set) var registryBlockedUntil: Date?
    public private(set) var registryLastAttemptAt: Date?
    /// Registry calls made, for diagnostics and tests.
    public private(set) var registryCallCount = 0
    private var isRegistering = false
    /// A registry answer (the start on the local clock) whose record could
    /// not be saved yet. Retried on ticks; the registry is not asked again.
    private var pendingRegistrationStart: Date?
    /// The fallback device id the store is known to hold; only that id is
    /// ever sent.
    private var durableFallbackID: String?

    /// The record as it should be on disk while the last write has failed.
    private var pendingDurableWrite: LicenseRecord??
    /// The cleanups list on disk is behind memory.
    private var cleanupsDirty = false
    /// The cleanups on disk could not be read; nothing may overwrite them
    /// until they were merged in.
    private var cleanupsUnread = false
    /// A journal write the journal has not accepted yet, one per activation.
    /// Ordered by when it was asked for (`order`), never by its scope: the
    /// newest request for an activation supersedes older ones. Retried on ticks.
    private enum JournalOp: Equatable {
        case record(seq: UInt64)
        case clear(upTo: UInt64)
        /// Settle an unreadable entry with Dodo's answer.
        case replaceUnreadable(with: JournalEntry?)
    }
    private struct PendingJournalOp {
        let order: UInt64
        let op: JournalOp
    }
    private var pendingJournalOps: [String: PendingJournalOp] = [:]
    private var nextJournalOrder: UInt64 = 0
    /// Activations known to have a journal entry (written here or found on
    /// load), with the highest sequence known to be in it.
    private var journaledSeq: [String: UInt64] = [:]
    /// The instance whose record is being deleted, with its tombstone's
    /// sequence; the entry goes once the deletion is durable, or once a new
    /// record durably replaces it.
    private var removingInstance: (instanceID: String, seq: UInt64)?
    /// The journal could not be written; surfaced like a storage problem.
    public private(set) var journalError = false
    /// Activations whose journal entry on disk cannot be read; nothing
    /// overwrites it until an authoritative answer replaces it.
    private var unreadableJournalInstances: Set<String> = []
    /// Of those, the ones Dodo has not settled yet: their core stays off.
    private var restrictedInstances: Set<String> = []
    /// The current activation's journal entry on disk cannot be read.
    public var journalUnreadable: Bool {
        record.map { unreadableJournalInstances.contains($0.instanceID) } ?? false
    }
    /// The current activation waits for Dodo to settle its unreadable entry.
    private var isRestricted: Bool {
        record.map { restrictedInstances.contains($0.instanceID) } ?? false
    }
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
    /// Called on this actor right after memory changes and before storage is
    /// touched: the app layer locks the feature from here, synchronously.
    public private(set) var onChange: (@Sendable (LicenseSnapshot) -> Void)?

    public func setOnChange(_ handler: @escaping @Sendable (LicenseSnapshot) -> Void) {
        onChange = handler
        handler(snapshot)
    }

    /// Creates the manager without touching storage; call `load()` on the
    /// license actor to read what is stored.
    public nonisolated init(
        products: LicenseProducts, client: any LicenseClient, store: any LicenseStore,
        journal: any InvalidationJournal, trialStore: any TrialStore, registry: any TrialRegistryClient,
        device: any DeviceIdentity, trialTiming: TrialTiming = .standard, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.products = products
        self.client = client
        self.store = store
        self.journal = journal
        self.trialStore = trialStore
        self.registry = registry
        self.device = device
        self.trialTiming = trialTiming
        self.now = now
    }

    /// Reads the stored records, journal and cleanups, and starts a
    /// provisional trial on a Mac that has neither a license nor a trial
    /// record. Until it ran, there is no record: the feature is off.
    public func load() {
        reloadFromStore()
        settleTrial()
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
            if let stored = loaded, stored.isLegacyTrial || !products.isPaid(stored.productID) {
                // A retired trial key or another product is not a license:
                // it is ignored (and replaced by any activation), and the
                // trial rules apply.
                loaded = nil
            }
            if var current = loaded {
                do {
                    unreadableJournalInstances.remove(current.instanceID)
                    restrictedInstances.remove(current.instanceID)
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
                    unreadableJournalInstances.insert(current.instanceID)
                    restrictedInstances.insert(current.instanceID)
                    failure = error
                }
            }
            record = loaded
            licenseRead = true
        } catch {
            licenseRead = false
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
        notify()
        flushRecord()
        notify()
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
        snapshot.state(now: now())
    }

    /// What the app layer works from; `onChange` hands it over.
    public var snapshot: LicenseSnapshot {
        let current = now()
        return LicenseSnapshot(
            record: record, licenseRead: licenseRead, isRestricted: isRestricted, storageError: storageError,
            journalError: journalError, journalUnreadable: journalUnreadable,
            trial: trial, trialStorageError: trialApplies ? trialStorageError : nil, trialTiming: trialTiming,
            nextCheckAt: nextCheckDelay.map { current.addingTimeInterval($0) },
            nextDeadline: nextDeadline, hasPendingCleanups: !pendingCleanups.isEmpty
        )
    }

    /// Memory changed: tell the app layer before any storage runs.
    private func notify() {
        onChange?(snapshot)
    }

    public var isFeatureEnabled: Bool { state.isFeatureEnabled }

    /// The next moment the state changes on its own (a trial day boundary or
    /// its end, grace warning or end), independent of any network schedule.
    public var nextDeadline: Date? {
        if let record { return LicensePolicy.nextDeadline(record: record, now: now()) }
        guard licenseRead, let trial else { return nil }
        return LicensePolicy.nextTrialDeadline(trial, timing: trialTiming, now: now())
    }

    /// The trial is what decides the state: no license record, and that is known.
    private var trialApplies: Bool {
        licenseRead && record == nil
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
        if isRestricted, failedChecks == 0 { return true }
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
        if isCheckDue { candidates.append(0) }
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
        if let trialDelay = nextTrialTickDelay(now: current) { candidates.append(trialDelay) }
        return candidates.min()
    }

    /// The trial's share of the schedule: registration (due now, after
    /// `Retry-After`, or after backoff), a trial save that failed or cannot
    /// wait, and the hourly `last_seen_at` save while the trial runs.
    private func nextTrialTickDelay(now current: Date) -> TimeInterval? {
        guard trialApplies else { return nil }
        var candidates: [TimeInterval] = []
        if trialStorageError != nil || (trialDirty && trialSaveRequired) {
            candidates.append(LicensePolicy.minimumRetryDelay)
        }
        guard let trial else { return candidates.min() }
        if isRegistrationDue {
            candidates.append(0)
        } else if !trial.registered {
            if let registryBlockedUntil, current < registryBlockedUntil {
                candidates.append(registryBlockedUntil.timeIntervalSince(current))
            } else if let last = registryLastAttemptAt, registryFailures > 0 {
                let wait = LicensePolicy.retryDelay(afterFailures: registryFailures)
                candidates.append(max(0, last.addingTimeInterval(wait).timeIntervalSince(current)))
            }
        }
        if LicensePolicy.trialState(trial, timing: trialTiming, now: current) != .trialEnded {
            let since = lastTrialSaveAt.map { max(0, current.timeIntervalSince($0)) } ?? 0
            candidates.append(max(0, LicensePolicy.trialSaveInterval - since))
        }
        return candidates.min()
    }

    // MARK: Serialization

    /// Runs `operation` after every earlier operation has finished.
    private func perform<T: Sendable>(_ operation: @escaping @LicenseActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @LicenseActor in
            await previous?.value
            return await operation()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    /// Updates the record in memory first, then on disk. A failed write is
    /// remembered and retried; it never undoes the in-memory change.
    private func write(_ newRecord: LicenseRecord?) {
        setRecord(newRecord)
        flushRecord()
        notify() // what storage said
    }

    /// The in-memory change, published before any storage runs.
    private func setRecord(_ newRecord: LicenseRecord?) {
        record = newRecord
        pendingDurableWrite = .some(newRecord)
        notify() // enforcement first, storage second
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
        request(.record(seq: entry.seq), for: instanceID)
    }

    /// Removes a journal entry up to `seq`; retried on ticks until it is
    /// really gone. A newer entry for the activation is never touched.
    private func clearJournal(_ instanceID: String, upTo seq: UInt64) {
        request(.clear(upTo: seq), for: instanceID)
    }

    /// Settles an unreadable entry with Dodo's answer.
    private func replaceUnreadableJournal(_ instanceID: String, with entry: JournalEntry?) {
        if let entry { journaledSeq[instanceID] = max(journaledSeq[instanceID] ?? 0, entry.seq) }
        request(.replaceUnreadable(with: entry), for: instanceID)
    }

    /// A new journal request is the newest for its activation: it replaces
    /// whatever was still waiting, then runs now (and on ticks until done).
    private func request(_ op: JournalOp, for instanceID: String) {
        nextJournalOrder += 1
        let pending = PendingJournalOp(order: nextJournalOrder, op: op)
        pendingJournalOps[instanceID] = pending
        run(pending, for: instanceID)
    }

    /// Runs a pending journal operation; only the newest one for the
    /// activation is ever run, and it is dropped once the journal took it.
    private func run(_ pending: PendingJournalOp, for instanceID: String) {
        guard pendingJournalOps[instanceID]?.order == pending.order else { return }
        let done: Bool
        switch pending.op {
        case .record(let seq):
            done = journal.record(instanceID: instanceID, entry: JournalEntry(seq: seq))
        case .clear(let upTo):
            done = journal.clear(instanceID: instanceID, upTo: upTo)
        case .replaceUnreadable(let entry):
            done = journal.replaceUnreadable(instanceID: instanceID, with: entry)
        }
        if done {
            pendingJournalOps[instanceID] = nil
            switch pending.op {
            case .clear(let upTo):
                if let known = journaledSeq[instanceID], known <= upTo { journaledSeq[instanceID] = nil }
            case .replaceUnreadable(let entry):
                unreadableJournalInstances.remove(instanceID)
                restrictedInstances.remove(instanceID)
                if entry == nil { journaledSeq[instanceID] = nil }
            case .record:
                break
            }
        }
        journalError = !pendingJournalOps.isEmpty
    }

    private func retryJournal() {
        for (instanceID, pending) in pendingJournalOps { run(pending, for: instanceID) }
        notify()
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
        guard pendingDurableWrite != nil || cleanupsDirty || !pendingJournalOps.isEmpty else {
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
        let previous = record
        setRecord(nil) // off at once, before any storage
        if let previous {
            journalRecord(previous.instanceID, entry: JournalEntry(seq: previous.eventSeq + 1))
            removingInstance = (previous.instanceID, previous.eventSeq + 1)
        }
        flushRecord()
        notify()
    }

    /// A new activation whose record the store already holds: the previous
    /// activation's record — and one whose deletion was still owed — is
    /// durably replaced, so their journal entries go.
    private func commitActivation(_ newRecord: LicenseRecord) {
        activationGeneration += 1
        // The replaced activation is dead for good: its entry, up to the
        // last sequence that activation reached, goes; so does the old
        // activation's journal restriction. The new activation's journal
        // status is established on its own.
        if let previous = record, previous.instanceID != newRecord.instanceID {
            restrictedInstances.remove(previous.instanceID)
            if let known = journaledSeq[previous.instanceID] {
                clearJournal(previous.instanceID, upTo: max(known, previous.eventSeq))
            }
        }
        if let removing = removingInstance, removing.instanceID != newRecord.instanceID {
            removingInstance = nil
            clearJournal(removing.instanceID, upTo: removing.seq)
        }
        do {
            if let entry = try journal.entry(instanceID: newRecord.instanceID) {
                // Dodo just created this activation: anything left about its
                // id is older than that.
                clearJournal(newRecord.instanceID, upTo: entry.seq)
            }
        } catch {
            unreadableJournalInstances.insert(newRecord.instanceID)
            restrictedInstances.insert(newRecord.instanceID)
            storageError = error
        }
        record = newRecord
        pendingDurableWrite = nil
        if !cleanupsDirty, !cleanupsUnread { storageError = nil }
        failedChecks = 0
        blockedUntil = nil
        lastAttemptAt = now()
        notify()
    }

    /// Invalidation takes effect immediately, whatever storage says: the
    /// restrictive state is published before any I/O, then the journal is
    /// written, then the Keychain — so a restart before the Keychain accepts
    /// the revoked record still finds it revoked.
    private func invalidate(_ current: LicenseRecord) {
        var revoked = current
        revoked.revokedAt = now()
        revoked.eventSeq = current.eventSeq + 1
        failedChecks = 0
        blockedUntil = nil
        setRecord(revoked) // enforcement first
        if unreadableJournalInstances.contains(current.instanceID) {
            // Dodo's answer supersedes whatever the unreadable entry said;
            // it is replaced only once the revocation is durable.
            replaceUnreadableJournal(current.instanceID, with: JournalEntry(seq: revoked.eventSeq))
        } else {
            journalRecord(current.instanceID, entry: JournalEntry(seq: revoked.eventSeq))
        }
        flushRecord()
        notify()
    }

    // MARK: Activation

    /// Activates `key` on this Mac. Only the app's paid product is kept.
    public func activate(key rawKey: String) async -> LicenseMessage {
        await perform { await self.activateNow(key: rawKey) }
    }

    private func activateNow(key rawKey: String) async -> LicenseMessage {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let blockedUntil, now() < blockedUntil {
            return .rateLimited(seconds: Int(blockedUntil.timeIntervalSince(now()).rounded(.up)))
        }
        // The same paid key on a live activation: keep it, just verify it.
        if let record, record.licenseKey == key, !record.isRevoked {
            callCount += 1
            lastAttemptAt = now()
            switch await client.validate(licenseKey: key, instanceID: record.instanceID) {
            case .valid(let serverDate):
                if let current = self.record, current.instanceID == record.instanceID { applySuccess(serverDate: serverDate, for: current) }
                return self.record?.isRevoked == false ? .alreadyActivated : .storageUnavailable
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
            guard products.isPaid(productID) else {
                // Another app's key, the wrong environment or a retired
                // trial product: give the slot back.
                await release(licenseKey: key, instanceID: instanceID)
                return .wrongProduct(productName: activation.productName)
            }
            let previous = record
            let anchor = activation.serverDate ?? now()
            let newRecord = LicenseRecord(
                licenseKey: key, instanceID: instanceID, productID: productID,
                activatedAt: activation.createdAt, lastSuccessAt: anchor, lastObservedAt: max(anchor, activation.createdAt)
            )
            // Persist first; announce success only once the record is durable.
            // The trial record is kept as it is.
            do {
                try store.saveRecord(newRecord)
            } catch {
                storageError = error
                await release(licenseKey: key, instanceID: instanceID)
                return .storageFailed
            }
            commitActivation(newRecord)
            if let previous, previous.instanceID != instanceID {
                // A different paid key: free the old activation so it does
                // not count against the limit.
                await release(licenseKey: previous.licenseKey, instanceID: previous.instanceID)
            }
            return pendingCleanups.isEmpty ? .activated : .cleanupPending
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
    /// an active rate limit. Without a license, an unregistered trial asks
    /// the registry instead.
    public func checkOnLaunch() async {
        await perform {
            self.noteTrialTime()
            await self.checkNow()
            if self.isRegistrationDue { await self.registerTrialNow() }
        }
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
    /// runs the check — or the trial registration — if it is due. `wake`
    /// (wake from sleep, the network back, "Try again") asks the registry
    /// without waiting out the backoff; a `Retry-After` still holds.
    public func tick(wake: Bool = false) async {
        await perform {
            self.retryStorage()
            self.settleTrial()
            self.commitPendingRegistration()
            self.noteTime()
            self.noteTrialTime()
            await self.retryCleanupsNow()
            if self.isCheckDue { await self.checkNow() }
            if self.isRegistrationDue || (wake && self.canRegister) { await self.registerTrialNow() }
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
        notify() // the scheduling state is settled now
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
        // The grant is saved first: it takes effect only once the Keychain
        // holds it. A refused save leaves the Mac as it was; the next check
        // (backoff applies) tries again.
        do {
            try store.saveRecord(updated)
        } catch {
            storageError = error
            failedChecks += 1
            notify()
            return
        }
        if unreadableJournalInstances.contains(current.instanceID) {
            // Dodo settled what the unreadable entry might have said: the
            // journal is rebuilt without it, atomically. The restriction is
            // lifted only once that rebuild is durable (retried on ticks).
            replaceUnreadableJournal(current.instanceID, with: nil)
            if pendingJournalOps[current.instanceID] == nil { restrictedInstances.remove(current.instanceID) }
        }
        record = updated
        pendingDurableWrite = nil
        if !cleanupsDirty, !cleanupsUnread, !journalUnreadable { storageError = nil }
        if let known = journaledSeq[current.instanceID], known <= updated.eventSeq {
            clearJournal(current.instanceID, upTo: updated.eventSeq)
        }
        failedChecks = 0
        blockedUntil = nil
        notify()
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

    /// "Remove this Mac": deactivates, then clears the license record. The
    /// trial record stays, so the Mac goes back to Trial or TrialEnded.
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
                // A trial record that was never written (wiped meanwhile)
                // starts provisionally and asks the registry for the original start.
                self.settleTrial()
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
        blockedUntil = now().addingTimeInterval(Self.bounded(seconds))
    }

    private static func bounded(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(max(1, seconds), 86_400) : 60
    }

    // MARK: Trial

    /// Reads the trial record once it has not been read, and starts a
    /// provisional trial when the trial record is positively absent. Only
    /// without a license record: while one exists the trial record is not
    /// even read. Nothing is created over a record that could not be read.
    private func settleTrial() {
        guard trialApplies else { return }
        if trialLoad == .unread { readTrial() }
        if trialLoad == .absent, trialApplies { startProvisionalTrial() }
    }

    private func readTrial() {
        do {
            if let stored = try trialStore.loadTrial() {
                trial = stored
                trialLoad = .present
                lastTrialSaveAt = now()
            } else {
                trial = nil
                trialLoad = .absent
            }
            durableFallbackID = trial?.fallbackDeviceID
            pendingRegistrationStart = nil
            trialStorageError = nil
            trialDirty = false
            trialSaveRequired = false
            trialGeneration += 1
        } catch {
            trialStorageError = error
        }
        notify()
    }

    /// Starting the trial grants access, so the record is saved first and
    /// the core turns on only once it is durable. A failed save leaves the
    /// record unread: the next attempt reads before it writes.
    private func startProvisionalTrial() {
        let current = now()
        let fallback = device.hardwareUUID() == nil ? UUID().uuidString.lowercased() : nil
        let provisional = TrialRecord(startedAt: current, lastSeenAt: current, registered: false, fallbackDeviceID: fallback)
        do {
            try trialStore.saveTrial(provisional)
        } catch {
            trialStorageError = error
            trialLoad = .unread
            notify()
            return
        }
        trial = provisional
        trialLoad = .present
        durableFallbackID = fallback
        pendingRegistrationStart = nil
        trialStorageError = nil
        trialDirty = false
        trialSaveRequired = false
        trialEndSaved = false
        trialGeneration += 1
        lastTrialSaveAt = current
        registryFailures = 0
        registryLastAttemptAt = nil
        notify()
    }

    /// Saves the trial record as it is in memory. A failure is retried on
    /// every tick and shown; it never changes the trial's state.
    private func flushTrial() {
        guard let trial else { return }
        do {
            try trialStore.saveTrial(trial)
            trialDirty = false
            trialSaveRequired = false
            trialStorageError = nil
            durableFallbackID = trial.fallbackDeviceID
            lastTrialSaveAt = now()
            if LicensePolicy.trialState(trial, timing: trialTiming, now: now()) == .trialEnded { trialEndSaved = true }
        } catch {
            trialStorageError = error
            trialSaveRequired = true
        }
    }

    /// Raises `last_seen_at` in memory; saves it hourly, once when the trial
    /// has ended, whenever a save is owed, and on quit (`force`).
    private func noteTrialTime(force: Bool = false) {
        guard trialApplies, var updated = trial else { return }
        let current = now()
        if current > updated.lastSeenAt {
            updated.lastSeenAt = current
            trial = updated
            trialDirty = true
        }
        let ended = LicensePolicy.trialState(updated, timing: trialTiming, now: current) == .trialEnded
        let hourly = lastTrialSaveAt.map {
            current.timeIntervalSince($0) >= LicensePolicy.trialSaveInterval || current < $0
        } ?? true
        notify() // memory first
        if trialDirty, force || trialSaveRequired || trialStorageError != nil || hourly || (ended && !trialEndSaved) {
            flushTrial()
            notify()
        } else if ended, !trialDirty {
            trialEndSaved = true
        }
    }

    /// On quit: the latest `last_seen_at` is saved. Runs on the license
    /// actor at once, not behind a queued network call.
    public func saveTrialBeforeQuit() {
        noteTrialTime(force: true)
    }

    /// An unregistered trial may ask the registry now, ignoring backoff but
    /// not a `Retry-After`.
    private var canRegister: Bool {
        guard trialApplies, let trial, !trial.registered, !isRegistering, pendingRegistrationStart == nil else { return false }
        if let registryBlockedUntil, now() < registryBlockedUntil { return false }
        return true
    }

    /// Registration is due: never tried, or the backoff after the last
    /// failure (1 min doubling to 1 h) has passed.
    public var isRegistrationDue: Bool {
        guard canRegister else { return false }
        guard registryFailures > 0, let last = registryLastAttemptAt else { return true }
        let current = now()
        if current < last { return true } // the clock went back since
        return current >= last.addingTimeInterval(LicensePolicy.retryDelay(afterFailures: registryFailures))
    }

    /// Asks the registry for this Mac's start. The answer applies only to
    /// the trial record it was asked for.
    private func registerTrialNow() async {
        guard canRegister, var current = trial else { return }
        let deviceID: String
        if let hardware = device.hardwareUUID() {
            deviceID = hardware
        } else {
            // The same random id has to be used next time: it is sent only
            // once the store holds it, on every attempt.
            let fallback = current.fallbackDeviceID ?? UUID().uuidString.lowercased()
            if current.fallbackDeviceID == nil {
                current.fallbackDeviceID = fallback
                trial = current
                trialDirty = true
                trialSaveRequired = true
            }
            if durableFallbackID != fallback { flushTrial() }
            guard durableFallbackID == fallback else { notify(); return }
            deviceID = fallback
        }
        let generation = trialGeneration
        isRegistering = true
        defer { isRegistering = false }
        registryLastAttemptAt = now()
        registryCallCount += 1
        let result = await registry.register(device: TrialDevice.hash(app: Self.trialAppID, hardwareID: deviceID))
        guard generation == trialGeneration, trialApplies, let latest = trial, !latest.registered else {
            notify()
            return
        }
        switch result {
        case .registered(let startedAt, let serverNow):
            applyRegistration(startedAt: startedAt, serverNow: serverNow, to: latest)
        case .rateLimited(let retryAfter):
            registryFailures += 1
            registryBlockedUntil = now().addingTimeInterval(Self.bounded(retryAfter))
        case .unreachable:
            registryFailures += 1
        }
        notify()
    }

    /// The registry's start, converted to the local clock
    /// (`local_now − (registry_now − registry_started_at)`); the earlier of
    /// that and the provisional start wins. The registry has answered, so it
    /// is not asked again; the record is committed now or on a later tick.
    private func applyRegistration(startedAt: Date, serverNow: Date, to latest: TrialRecord) {
        let used = max(0, serverNow.timeIntervalSince(startedAt))
        pendingRegistrationStart = min(latest.startedAt, now().addingTimeInterval(-used))
        registryFailures = 0
        registryBlockedUntil = nil
        commitPendingRegistration()
    }

    /// When a trial record's access ends: the offline limit while
    /// unregistered, the full length once registered.
    private func entitlementEnd(_ record: TrialRecord) -> Date {
        let limit = record.registered ? trialTiming.duration : min(trialTiming.offlineLimit, trialTiming.duration)
        return record.startedAt.addingTimeInterval(limit)
    }

    /// Registers the trial record. Anything that lets access run longer than
    /// the record in memory allows is saved first and published only once
    /// the store holds it: until then the provisional deadline keeps
    /// applying, and a failed save is retried on ticks. A registration that
    /// shortens or ends the trial takes effect in memory first, then is saved.
    private func commitPendingRegistration() {
        guard let start = pendingRegistrationStart else { return }
        guard trialApplies, let latest = trial, !latest.registered else {
            pendingRegistrationStart = nil
            return
        }
        let current = now()
        var updated = latest
        updated.startedAt = min(latest.startedAt, start)
        updated.lastSeenAt = max(latest.lastSeenAt, current)
        updated.registered = true
        if entitlementEnd(updated) > entitlementEnd(latest) {
            do {
                try trialStore.saveTrial(updated)
            } catch {
                trialStorageError = error
                notify()
                return
            }
            pendingRegistrationStart = nil
            trial = updated
            trialDirty = false
            trialSaveRequired = false
            trialStorageError = nil
            durableFallbackID = updated.fallbackDeviceID
            lastTrialSaveAt = current
            if LicensePolicy.trialState(updated, timing: trialTiming, now: current) == .trialEnded { trialEndSaved = true }
            notify()
        } else {
            pendingRegistrationStart = nil
            trial = updated
            trialDirty = true
            trialSaveRequired = true
            notify() // enforcement first
            flushTrial()
            notify()
        }
    }
}
