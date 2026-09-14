import Foundation
import OpenReactionCore
import Testing

/// The shared test cases from LICENSING.md, numbered as there, against a
/// fake Dodo client, a fake trial registry, fake Keychain items and an
/// injectable clock. Cases 12–27 (the in-app trial) are in
/// `TrialLicensingTests.swift`.
@Suite("Licensing")
@LicenseActor
struct LicensingTests {
    static let paid = "pdt_openreaction_PAID"
    /// The retired Dodo trial product: refused like any other product.
    static let retiredTrial = "pdt_openreaction_TRIAL"
    static let other = "pdt_openklack_PAID"
    static let products = LicenseProducts(paid: [paid])

    final class Clock: @unchecked Sendable {
        static let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = Clock.start
        /// The monotonic clock: moves forward with `advance`, never back.
        var uptime: TimeInterval = 1_000
        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            uptime += max(0, seconds)
        }
        static let day: TimeInterval = 86_400
    }

    /// Lets a test hold a response until it says so.
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    final class FakeClient: LicenseClient, @unchecked Sendable {
        enum Call: Equatable { case activate(key: String, name: String), validate(instance: String), deactivate(instance: String) }
        var calls: [Call] = []
        var activation: ActivationResult = .unreachable
        var validation: ValidationResult = .unreachable
        var deactivation: DeactivationResult = .deactivated
        /// When set, validations wait here before answering.
        var validationGate: Gate?

        func activate(licenseKey: String, name: String) async -> ActivationResult {
            calls.append(.activate(key: licenseKey, name: name))
            return activation
        }

        func validate(licenseKey: String, instanceID: String) async -> ValidationResult {
            calls.append(.validate(instance: instanceID))
            if let validationGate { await validationGate.wait() }
            return validation
        }

        func deactivate(licenseKey: String, instanceID: String) async -> DeactivationResult {
            calls.append(.deactivate(instance: instanceID))
            return deactivation
        }
    }

    final class MemoryStore: LicenseStore, @unchecked Sendable {
        var record: LicenseRecord?
        var pendingCleanups: [PendingCleanup] = []
        var failsWrites = false
        var failsReads = false
        var cleanupReadError: LicenseStoreError?
        func loadRecord() throws(LicenseStoreError) -> LicenseRecord? {
            if failsReads { throw .unavailable("locked") }
            return record
        }
        func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
            if failsWrites { throw .unavailable("denied") }
            self.record = record
        }
        func clearRecord() throws(LicenseStoreError) {
            if failsWrites { throw .unavailable("denied") }
            record = nil
        }
        func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] {
            if failsReads { throw .unavailable("locked") }
            if let cleanupReadError { throw cleanupReadError }
            return pendingCleanups
        }
        func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {
            if failsWrites { throw .unavailable("denied") }
            pendingCleanups = cleanups
        }
    }

    final class MemoryJournal: InvalidationJournal, @unchecked Sendable {
        var entries: [String: JournalEntry] = [:]
        var failsWrites = false
        /// Activations whose entry reads as corrupt (whatever `entries` holds
        /// for them stands in for the unreadable bytes).
        var unreadable: Set<String> = []
        /// A read error for every activation.
        var readError: LicenseStoreError?
        func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? {
            if let readError { throw readError }
            if unreadable.contains(instanceID) { throw .corrupt }
            return entries[instanceID]
        }
        private func isUnreadable(_ instanceID: String) -> Bool { readError != nil || unreadable.contains(instanceID) }
        func record(instanceID: String, entry: JournalEntry) -> Bool {
            if !isUnreadable(instanceID), let existing = entries[instanceID], existing.seq >= entry.seq { return true }
            guard !failsWrites else { return false }
            entries[instanceID] = entry
            unreadable.remove(instanceID)
            if readError != nil { readError = nil } // the rebuilt journal is readable again
            return true
        }
        func clear(instanceID: String, upTo seq: UInt64) -> Bool {
            if isUnreadable(instanceID) { return false }
            if let existing = entries[instanceID], existing.seq > seq { return true }
            guard !failsWrites else { return false }
            entries[instanceID] = nil
            return true
        }
        func replaceUnreadable(instanceID: String, with entry: JournalEntry?) -> Bool {
            guard isUnreadable(instanceID) else { return true }
            guard !failsWrites else { return false }
            entries[instanceID] = entry
            unreadable.remove(instanceID)
            readError = nil
            return true
        }
    }

    /// The trial record as a Keychain item: absent, readable, or failing.
    final class MemoryTrialStore: TrialStore, @unchecked Sendable {
        /// By default this Mac's trial ended long ago and is registered, so
        /// the license cases start from TrialEnded with no registry calls.
        var record: TrialRecord? = TrialRecord(startedAt: Clock.start.addingTimeInterval(-10 * Clock.day), registered: true)
        var readError: LicenseStoreError?
        var failsWrites = false
        private(set) var saves: [TrialRecord] = []
        private(set) var loads = 0
        func loadTrial() throws(LicenseStoreError) -> TrialRecord? {
            loads += 1
            if let readError { throw readError }
            return record
        }
        func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError) {
            if failsWrites { throw .unavailable("denied") }
            saves.append(trial)
            record = trial
        }
    }

    final class FakeRegistry: TrialRegistryClient, @unchecked Sendable {
        var devices: [String] = []
        var result: TrialRegistrationResult = .unreachable
        /// When set, answers wait here.
        var gate: Gate?
        func register(device: String) async -> TrialRegistrationResult {
            devices.append(device)
            if let gate { await gate.wait() }
            return result
        }
    }

    final class FakeDevice: DeviceIdentity, @unchecked Sendable {
        var uuid: String? = "00000000-1111-2222-3333-444444444444"
        func hardwareUUID() -> String? { uuid }
    }

    let clock = Clock()
    let client = FakeClient()
    let store = MemoryStore()
    let journal = MemoryJournal()
    let trialStore = MemoryTrialStore()
    let registry = FakeRegistry()
    let device = FakeDevice()

    /// A manager that has read storage (the app calls `load` on start).
    func makeManager() -> LicenseManager {
        let clock = self.clock
        let manager = LicenseManager(
            products: Self.products, client: client, store: store, journal: journal,
            trialStore: trialStore, registry: registry, device: device, now: { clock.now }, uptime: { clock.uptime }
        )
        manager.load()
        return manager
    }

    func activation(_ product: String, name: String = "OpenReaction", instance: String = "inst_1") -> Activation {
        Activation(instanceID: instance, productID: product, productName: name, createdAt: clock.now, serverDate: clock.now)
    }

    /// A paid record whose last success was `age` seconds ago.
    func paidRecord(lastSuccessAge age: TimeInterval) -> LicenseRecord {
        LicenseRecord(
            licenseKey: "KEY-PAID", instanceID: "inst_1", productID: Self.paid,
            activatedAt: clock.now.addingTimeInterval(-30 * Clock.day), lastSuccessAt: clock.now.addingTimeInterval(-age)
        )
    }

    /// A trial record with `elapsed` seconds used, observed up to now.
    func trialRecord(elapsed: TimeInterval, registered: Bool = true) -> TrialRecord {
        TrialRecord(startedAt: clock.now.addingTimeInterval(-elapsed), lastSeenAt: clock.now, registered: registered)
    }

    // MARK: Activation

    @Test("1. Paid key activates and is stored, from Trial or TrialEnded", arguments: [false, true])
    func case1_paidKeyActivates(duringTrial: Bool) async {
        if duringTrial { trialStore.record = trialRecord(elapsed: Clock.day) }
        let trialBefore = trialStore.record
        client.activation = .activated(activation(Self.paid))
        let manager = makeManager()
        #expect(manager.state == (duringTrial ? .trial(daysLeft: 2) : .trialEnded))
        let message = await manager.activate(key: " KEY-PAID\n")
        #expect(message == .activated)
        #expect(manager.state == .licensed)
        #expect(manager.isFeatureEnabled)
        #expect(store.record?.productID == Self.paid)
        #expect(store.record?.licenseKey == "KEY-PAID")
        #expect(store.record?.instanceID == "inst_1")
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac")])
        // Buying keeps the trial record as it was, and deactivates nothing.
        #expect(trialStore.record == trialBefore)
    }

    @Test("2. Another app's key is deactivated again and nothing is saved")
    func case2_foreignKeyIsRefused() async {
        client.activation = .activated(activation(Self.other, name: "OpenKlack", instance: "inst_x"))
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-X")
        #expect(message == .wrongProduct(productName: "OpenKlack"))
        #expect(message.text == "This key is for OpenKlack, not OpenReaction.")
        #expect(store.record == nil)
        #expect(manager.state == .trialEnded)
        #expect(client.calls == [.activate(key: "KEY-X", name: "Mac"), .deactivate(instance: "inst_x")])
    }

    @Test("2. A key for the retired trial product is refused like another app's key")
    func retiredTrialProductIsRefused() async {
        trialStore.record = trialRecord(elapsed: Clock.day)
        client.activation = .activated(activation(Self.retiredTrial, name: "OpenReaction Trial", instance: "inst_t"))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-TRIAL") == .wrongProduct(productName: "OpenReaction Trial"))
        #expect(store.record == nil)
        #expect(manager.state == .trial(daysLeft: 2))
        #expect(client.calls == [.activate(key: "KEY-TRIAL", name: "Mac"), .deactivate(instance: "inst_t")])
    }

    @Test("3. Activation limit reached")
    func case3_limitReached() async {
        client.activation = .activationLimitReached
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .allMacsActivated)
        #expect(message.text.contains("All 3 Macs"))
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
    }

    @Test("4. Key not found / disabled", arguments: [
        (ActivationResult.keyNotFound, LicenseMessage.keyNotFound),
        (ActivationResult.keyDisabledOrExpired, LicenseMessage.keyDisabledOrExpired),
    ])
    func case4_notFoundOrDisabled(result: ActivationResult, expected: LicenseMessage) async {
        client.activation = result
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY") == expected)
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
    }

    @Test("5. Activation timeout saves nothing")
    func case5_timeout() async {
        client.activation = .unreachable
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .unreachable)
        #expect(message.text.hasPrefix("Couldn’t reach the license service"))
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
    }

    // MARK: Daily check and grace

    @Test("6. A check runs once the last success is over 24 h old")
    func case6_dailyCheckRuns() async {
        store.record = paidRecord(lastSuccessAge: 25 * 3600)
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        #expect(manager.isCheckDue)
        #expect(await manager.checkIfDue())
        #expect(client.calls == [.validate(instance: "inst_1")])
        #expect(store.record?.lastSuccessAt == clock.now)
        // Not due again until tomorrow.
        #expect(!manager.isCheckDue)
        #expect(manager.nextCheckDelay == LicensePolicy.checkInterval)
        #expect(await manager.checkIfDue() == false)
        clock.advance(LicensePolicy.checkInterval)
        #expect(manager.isCheckDue)
    }

    @Test("7. Two days offline is grace: feature on")
    func case7_graceKeepsFeatureOn() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        client.validation = .unreachable
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .grace(daysLeft: 5, showWarning: false))
        #expect(manager.isFeatureEnabled)
        #expect(store.record?.lastSuccessAt == clock.now.addingTimeInterval(-2 * Clock.day))
    }

    @Test("Grace shows the warning after five days offline")
    func graceWarningAfterFiveDays() {
        store.record = paidRecord(lastSuccessAge: 5 * Clock.day + 60)
        let manager = makeManager()
        #expect(manager.state == .grace(daysLeft: 2, showWarning: true))
        #expect(manager.isFeatureEnabled)
    }

    @Test("8. Eight days offline requires a check: feature off")
    func case8_checkRequiredAfterAWeek() async {
        store.record = paidRecord(lastSuccessAge: 8 * Clock.day)
        client.validation = .unreachable
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .checkRequired)
        #expect(!manager.isFeatureEnabled)
        // Still a license: nothing was revoked or deleted.
        #expect(store.record != nil)
    }

    @Test("9. A successful check ends CheckRequired")
    func case9_checkSucceeds() async {
        store.record = paidRecord(lastSuccessAge: 8 * Clock.day)
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        let serverDate = clock.now.addingTimeInterval(-5)
        client.validation = .valid(serverDate: serverDate)
        await manager.check()
        #expect(manager.state == .licensed)
        #expect(store.record?.lastSuccessAt == serverDate)
    }

    @Test("10. valid:false revokes")
    func case10_revoked() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(!manager.isFeatureEnabled)
        // A later network failure cannot make it better or worse.
        client.validation = .unreachable
        await manager.check()
        #expect(manager.state == .revoked)
    }

    @Test("L2. Revocation survives a restart and an offline launch")
    func revocationPersists() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        await makeManager().check()
        #expect(store.record?.isRevoked == true)
        // Restart, offline.
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .revoked)
        await restarted.checkOnLaunch()
        #expect(restarted.state == .revoked)
        #expect(!restarted.isFeatureEnabled)
        // Only an authoritative valid:true for this activation clears it.
        client.validation = .valid(serverDate: nil)
        await restarted.check()
        #expect(restarted.state == .licensed)
        #expect(store.record?.isRevoked == false)
    }

    @Test("11. Clock rollback does not extend grace")
    func case11_clockRollback() {
        store.record = paidRecord(lastSuccessAge: 3 * Clock.day)
        clock.advance(-5 * Clock.day) // local clock now 2 days before last_success_at
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        #expect(manager.isCheckDue)
        #expect(!manager.isFeatureEnabled)
    }

    @Test("P0-4. A successful check re-anchors time from the server Date")
    func serverDateReanchorsAfterRollback() async {
        // The clock had jumped ahead ten days (observed), then was corrected:
        // locally that looks like a rollback. Dodo's Date settles it.
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .unreachable
        let manager = makeManager()
        clock.advance(10 * Clock.day)
        await manager.tick()
        clock.advance(-10 * Clock.day)
        #expect(manager.state == .checkRequired)
        #expect(manager.isCheckDue)
        client.validation = .valid(serverDate: clock.now)
        await manager.tick()
        #expect(store.record?.lastObservedAt == clock.now) // lowered by ten days: the server said so
        #expect(manager.state == .licensed)
        #expect(manager.isFeatureEnabled)
    }

    @Test("P0-4. A check with the clock still wrong does not unlock")
    func checkWithWrongClockStaysLocked() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .unreachable
        let manager = makeManager()
        await manager.tick()
        let real = clock.now.addingTimeInterval(3600)
        clock.advance(-30 * Clock.day)
        client.validation = .valid(serverDate: real)
        await manager.check()
        // Re-anchored to the server, but this Mac's clock is still 30 days
        // behind it: nothing local can be trusted yet.
        #expect(store.record?.lastObservedAt == real)
        #expect(manager.state == .checkRequired)
    }

    @Test("P0-4. A paid license with the clock rolled back needs a check")
    func paidClockRollbackNeedsCheck() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        let manager = makeManager()
        clock.advance(2 * Clock.day)
        await manager.tick() // unreachable: time observed anyway
        clock.advance(-2 * Clock.day - 7200)
        #expect(manager.state == .checkRequired)
        #expect(manager.nextDeadlineDelay == nil)
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(manager.state == .licensed)
    }

    @Test("L3. Time observed by the app is remembered")
    func tickRaisesTheHighWaterMark() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .unreachable
        let manager = makeManager()
        clock.advance(0.5 * Clock.day)
        await manager.tick()
        #expect(store.record?.lastObservedAt == clock.now)
        clock.advance(-10 * Clock.day)
        #expect(manager.state == .checkRequired)
    }

    @Test("L3. Deadlines are local and independent of the network schedule")
    func localDeadlines() {
        trialStore.record = trialRecord(elapsed: 3 * Clock.day - 2.4 * 3600)
        var manager = makeManager()
        #expect(manager.nextDeadlineDelay == (2.4 * 3600))
        #expect(manager.nextCheckDelay == LicensePolicy.trialSaveInterval) // no license: only the hourly trial save
        store.record = paidRecord(lastSuccessAge: 3600)
        manager = makeManager()
        // Daily due, then the five-day warning, then the end of grace.
        #expect(manager.nextDeadlineDelay == (LicensePolicy.checkInterval - 3600))
        clock.advance(2 * Clock.day)
        #expect(manager.nextDeadlineDelay == (LicensePolicy.graceWarningAfter - 2 * Clock.day - 3600))
        clock.advance(4 * Clock.day)
        #expect(manager.nextDeadlineDelay == (LicensePolicy.graceDuration - 6 * Clock.day - 3600))
        clock.advance(2 * Clock.day)
        #expect(manager.nextDeadlineDelay == nil)
        #expect(manager.state == .checkRequired)
    }

    @Test("A network failure never revokes")
    func networkFailureNeverRevokes() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .unreachable
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .licensed)
        #expect(manager.failedChecks == 1)
        #expect(manager.nextCheckDelay == 60)
    }

    @Test("L7. Failed checks back off 1 min → 1 h, then return to the daily schedule")
    func backoff() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .unreachable
        let manager = makeManager()
        var delays: [TimeInterval] = []
        for _ in 0..<LicensePolicy.maximumRetries {
            await manager.checkIfDue()
            delays.append(manager.nextCheckDelay ?? -1)
            clock.advance(manager.nextCheckDelay ?? 0)
        }
        #expect(delays == [60, 120, 240, 480, 960, 1920, 3600, 3600])
        // The retry budget is spent: back to once a day.
        await manager.checkIfDue()
        #expect(manager.nextCheckDelay == LicensePolicy.checkInterval)
        #expect(!manager.isCheckDue)
        #expect(manager.state == .licensed) // still within the day; never revoked by failures
    }

    @Test("L7. An invalid answer does not cause a check loop")
    func invalidAnswerDoesNotLoop() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        client.validation = .invalid
        let manager = makeManager()
        await manager.checkIfDue()
        #expect(manager.state == .revoked)
        #expect(!manager.isCheckDue)
        #expect(manager.nextCheckDelay == LicensePolicy.checkInterval)
        #expect(await manager.checkIfDue() == false)
        #expect(client.calls.count == 1)
    }

    @Test("L7. The launch check runs even for a recent record")
    func launchCheckRunsForRecentRecord() async {
        store.record = paidRecord(lastSuccessAge: 60)
        client.validation = .valid(serverDate: nil)
        let manager = makeManager()
        await manager.checkOnLaunch()
        #expect(client.calls.count == 1)
        // And it is not repeated until tomorrow.
        #expect(!manager.isCheckDue)
        #expect(await manager.checkIfDue() == false)
        #expect(client.calls.count == 1)
    }

    @Test("L7. Removal honors an active Retry-After")
    func removalHonorsRateLimit() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        client.validation = .rateLimited(retryAfter: 120)
        let manager = makeManager()
        await manager.check()
        let calls = client.calls.count
        #expect(await manager.removeThisMac() == .rateLimited(seconds: 120))
        #expect(client.calls.count == calls)
        #expect(manager.state == .grace(daysLeft: 5, showWarning: false))
    }

    @Test("One check at a time, and operations run in order")
    func oneCheckAtATime() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        client.validation = .valid(serverDate: nil)
        let manager = makeManager()
        async let first: Bool = manager.checkIfDue()
        async let second: Bool = manager.checkIfDue()
        _ = await (first, second)
        #expect(client.calls.count == 1)
    }

    // MARK: L1 — late answers never touch a newer record

    @Test("L1. A late valid:true for the old key cannot overwrite a new paid activation")
    func lateValidDoesNotOverwriteNewActivation() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        let gate = Gate()
        client.validationGate = gate
        client.validation = .valid(serverDate: nil)
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let pendingCheck = Task { await manager.check() }
        await Task.yield()
        let pendingActivate = Task { await manager.activate(key: "KEY-PAID-2") }
        await Task.yield()
        await gate.release()
        await pendingCheck.value
        #expect(await pendingActivate.value == .activated)
        #expect(store.record?.instanceID == "inst_p")
        #expect(store.record?.licenseKey == "KEY-PAID-2")
        #expect(manager.state == .licensed)
    }

    @Test("L1. A late valid:false revokes the old record, not the new paid one")
    func lateInvalidDoesNotRevokeNewRecord() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        let gate = Gate()
        client.validationGate = gate
        client.validation = .invalid
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let pendingCheck = Task { await manager.check() }
        await Task.yield()
        let pendingActivate = Task { await manager.activate(key: "KEY-PAID-2") }
        await Task.yield()
        await gate.release()
        await pendingCheck.value
        _ = await pendingActivate.value
        #expect(manager.state == .licensed)
        #expect(store.record?.isRevoked == false)
    }

    @Test("L1. A late valid:true cannot resurrect a removed activation")
    func lateValidDoesNotResurrectRemoved() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        let gate = Gate()
        client.validationGate = gate
        client.validation = .valid(serverDate: nil)
        let manager = makeManager()
        let pendingCheck = Task { await manager.check() }
        await Task.yield()
        let pendingRemove = Task { await manager.removeThisMac() }
        await Task.yield()
        await gate.release()
        await pendingCheck.value
        #expect(await pendingRemove.value == .removed)
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
    }

    // MARK: L4 — storage failures

    @Test("L4. A record that cannot be saved is not announced; the activation is released")
    func storageFailureReleasesActivation() async {
        store.failsWrites = true
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .storageFailed)
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac"), .deactivate(instance: "inst_p")])
    }

    @Test("L4. Buying during a trial keeps the trial if the paid record cannot be saved")
    func paidDuringTrialStorageFailureKeepsTrial() async {
        trialStore.record = trialRecord(elapsed: Clock.day)
        store.failsWrites = true
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .storageFailed)
        #expect(store.record == nil)
        #expect(manager.state == .trial(daysLeft: 2))
        #expect(manager.isFeatureEnabled)
    }

    @Test("L4. Unreadable storage is reported, and no trial runs over an unreadable license")
    func unreadableStorageIsReported() async {
        store.failsReads = true
        trialStore.record = nil // a fresh Mac, as far as the trial is concerned
        let manager = makeManager()
        #expect(manager.storageError == .unavailable("locked"))
        #expect(manager.state == .trialUnavailable)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.nextCheckDelay == LicenseManager.cleanupRetryInterval)
        // The license might be revoked: nothing starts a trial meanwhile.
        #expect(trialStore.saves.isEmpty)
        await manager.tick()
        #expect(registry.devices.isEmpty)
        #expect(client.calls.isEmpty)
        // Storage back: the next tick reads it.
        store.failsReads = false
        store.record = paidRecord(lastSuccessAge: 60)
        client.validation = .valid(serverDate: nil)
        await manager.tick()
        #expect(manager.storageError == nil)
        #expect(manager.state == .licensed)
    }

    // MARK: L6 — repeated paid activation

    @Test("L6. Activating the same paid key again reuses the activation")
    func samePaidKeyAgainReusesInstance() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .valid(serverDate: nil)
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .alreadyActivated)
        #expect(client.calls == [.validate(instance: "inst_1")])
        #expect(store.record?.instanceID == "inst_1")
    }

    @Test("L6. A different paid key frees the previous activation")
    func differentPaidKeyFreesPrevious() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.activation = .activated(activation(Self.paid, instance: "inst_2"))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID-2") == .activated)
        #expect(store.record?.instanceID == "inst_2")
        #expect(client.calls.contains(.deactivate(instance: "inst_1")))
    }

    @Test("L12. A cleanup that cannot reach Dodo is remembered and retried")
    func cleanupIsRetried() async {
        client.activation = .activated(activation(Self.other, name: "OpenKlack", instance: "inst_x"))
        client.deactivation = .unreachable
        let manager = makeManager()
        _ = await manager.activate(key: "KEY-X")
        #expect(manager.pendingCleanups.map(\.instanceID) == ["inst_x"])
        client.deactivation = .deactivated
        await manager.retryPendingCleanups()
        #expect(manager.pendingCleanups.isEmpty)
    }

    @Test("L12. Pending cleanups survive a restart and are scheduled without a license")
    func cleanupPersistsAcrossRestart() async {
        client.activation = .activated(activation(Self.other, name: "OpenKlack", instance: "inst_x"))
        client.deactivation = .unreachable
        _ = await makeManager().activate(key: "KEY-X")
        #expect(store.pendingCleanups == [PendingCleanup(licenseKey: "KEY-X", instanceID: "inst_x")])
        // Restart: unlicensed, but the cleanup is still owed and scheduled.
        let restarted = makeManager()
        #expect(restarted.state == .trialEnded)
        #expect(restarted.pendingCleanups.map(\.instanceID) == ["inst_x"])
        #expect(restarted.nextCheckDelay == LicenseManager.cleanupRetryInterval)
        client.deactivation = .deactivated
        await restarted.tick()
        #expect(restarted.pendingCleanups.isEmpty)
        #expect(store.pendingCleanups.isEmpty)
        #expect(restarted.nextCheckDelay == nil)
        #expect(client.calls.last == .deactivate(instance: "inst_x"))
    }

    @Test("T4. Unreadable cleanups are an error, keep retrying, and are never overwritten")
    func unreadableCleanupsAreNotOverwritten() async {
        store.pendingCleanups = [PendingCleanup(licenseKey: "KEY-OLD", instanceID: "inst_old")]
        store.cleanupReadError = .unavailable("locked")
        client.activation = .activated(activation(Self.other, name: "OpenKlack", instance: "inst_x"))
        client.deactivation = .unreachable
        let manager = makeManager()
        #expect(manager.storageError == .unavailable("locked"))
        #expect(manager.pendingCleanups.isEmpty)
        #expect(manager.nextCheckDelay == LicenseManager.cleanupRetryInterval) // no record, still scheduled
        // A new cleanup while the old ones cannot be read: remembered in
        // memory, but the store is not overwritten.
        _ = await manager.activate(key: "KEY-X")
        #expect(manager.pendingCleanups.map(\.instanceID) == ["inst_x"])
        #expect(store.pendingCleanups.map(\.instanceID) == ["inst_old"])
        #expect(manager.storageError != nil)
        // Readable again: merged, written, and both retried.
        store.cleanupReadError = nil
        client.deactivation = .deactivated
        await manager.tick()
        #expect(client.calls.suffix(2) == [.deactivate(instance: "inst_x"), .deactivate(instance: "inst_old")])
        #expect(manager.pendingCleanups.isEmpty)
        #expect(store.pendingCleanups.isEmpty)
        #expect(manager.storageError == nil)
    }

    @Test("T4. Corrupt cleanups are replaced, not kept as an error forever")
    func corruptCleanupsAreReplaced() async {
        store.cleanupReadError = .corrupt
        client.activation = .activated(activation(Self.other, name: "OpenKlack", instance: "inst_x"))
        client.deactivation = .unreachable
        let manager = makeManager()
        #expect(manager.storageError == .corrupt)
        _ = await manager.activate(key: "KEY-X")
        #expect(store.pendingCleanups.map(\.instanceID) == ["inst_x"])
        store.cleanupReadError = nil
        await manager.tick()
        #expect(manager.storageError == nil)
    }

    @Test("L12. A replaced activation that cannot be freed is owed after a restart")
    func replacedActivationCleanupPersists() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        client.deactivation = .unreachable
        #expect(await makeManager().activate(key: "KEY-PAID-2") == .cleanupPending)
        #expect(store.record?.instanceID == "inst_p")
        #expect(store.pendingCleanups.map(\.instanceID) == ["inst_1"])
        let restarted = makeManager()
        #expect(restarted.state == .licensed)
        #expect(restarted.pendingCleanups.map(\.instanceID) == ["inst_1"])
    }

    // MARK: L13 — malformed answers

    @Test("L13. Blank or control-character ids in a 201 are malformed: nothing is saved or released", arguments: [
        ("  ", "pdt_openreaction_PAID"), ("inst_1", ""), ("", " "), ("\n", "pdt_openreaction_PAID"),
        ("inst_1", "\r\n"), ("inst\u{0}1", "pdt_openreaction_PAID"), ("inst_1", "pdt_openreaction_PAID\u{1B}"),
    ])
    func blankIDsAreMalformed(instance: String, product: String) async {
        client.activation = .activated(Activation(instanceID: instance, productID: product, productName: "OpenReaction", createdAt: clock.now))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .malformedResponse)
        #expect(manager.state == .trialEnded)
        #expect(store.record == nil)
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac")])
    }

    @Test("L13. A malformed client answer is reported")
    func malformedClientAnswer() async {
        client.activation = .malformed
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .malformedResponse)
        #expect(store.record == nil)
    }

    // MARK: Removal

    @Test("24. Remove this Mac offline keeps the license")
    func case24_removeOffline() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.deactivation = .unreachable
        let manager = makeManager()
        let message = await manager.removeThisMac()
        #expect(message == .removeFailedOffline)
        #expect(manager.state == .licensed)
        #expect(store.record != nil)
    }

    // MARK: Rate limit and build flavour

    @Test("25. Dodo 429 blocks calls for Retry-After and changes nothing")
    func case25_rateLimited() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        client.validation = .rateLimited(retryAfter: 60)
        let manager = makeManager()
        let before = manager.state
        await manager.check()
        #expect(manager.state == before)
        #expect(manager.nextCheckDelay == 60)
        #expect(!manager.isCheckDue)
        // Activation is blocked too, without a call.
        let calls = client.calls.count
        #expect(await manager.activate(key: "KEY") == .rateLimited(seconds: 60))
        #expect(await manager.checkIfDue() == false)
        #expect(client.calls.count == calls)
        clock.advance(60)
        #expect(manager.isCheckDue)
    }

    @Test("26. Source builds have no licensing: no trial, feature on, no calls")
    func case26_sourceBuild() {
        // A build without OPENAPPS_LICENSING never creates a manager, so no
        // trial record is read or written and nothing calls out.
        let manager: LicenseManager? = nil
        #expect(LicenseGate.isFeatureEnabled(manager))
        #expect(client.calls.isEmpty)
        #expect(registry.devices.isEmpty)
        #expect(trialStore.loads == 0 && trialStore.saves.isEmpty)
    }

    // MARK: Policy details

    @Test("Record round-trips through Codable")
    func recordRoundTrip() throws {
        let record = paidRecord(lastSuccessAge: 10)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(LicenseRecord.self, from: data) == record)
    }

    @Test("A record saved with the old `kind` field still reads")
    func legacyKindFieldIsIgnored() throws {
        let record = paidRecord(lastSuccessAge: 10)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["kind"] = "paid"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(LicenseRecord.self, from: data) == record)
    }

    // MARK: P0-1 — the activation identity, not time, decides which answers count

    @Test("P0-1. Time observed while a check is pending does not discard its answer")
    func timeObservationDoesNotDiscardAPendingAnswer() async {
        store.record = paidRecord(lastSuccessAge: 8 * Clock.day)
        let gate = Gate()
        client.validationGate = gate
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        let pendingCheck = Task { await manager.check() }
        await Task.yield()
        clock.advance(3600)
        let pendingTick = Task { await manager.tick() }
        await Task.yield()
        await gate.release()
        await pendingCheck.value
        await pendingTick.value
        #expect(manager.state == .licensed)
        #expect(store.record?.lastSuccessAt == clock.now.addingTimeInterval(-3600))
        #expect(store.record?.lastObservedAt == clock.now)
        #expect(client.calls.count == 1)
    }

    @Test("P0-1. A late valid:true still lands on the same activation after a re-activation of the same key")
    func sameKeyValidationIsNotStale() async {
        store.record = paidRecord(lastSuccessAge: 8 * Clock.day)
        client.validation = .valid(serverDate: nil)
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .alreadyActivated)
        #expect(manager.state == .licensed)
        #expect(client.calls == [.validate(instance: "inst_1")])
    }

    // MARK: P0-2 — one invalidation path

    @Test("P0-2. valid:false locks at once even when the Keychain refuses; the write is retried")
    func invalidationLocksInMemoryAndRetriesTheWrite() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        let manager = makeManager()
        store.failsWrites = true
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.storageError == .unavailable("denied"))
        #expect(store.record?.isRevoked == false) // not durable yet
        #expect(manager.nextCheckDelay == LicenseManager.cleanupRetryInterval)
        // Still locked and still owed while storage keeps failing.
        client.validation = .unreachable
        await manager.tick()
        #expect(manager.state == .revoked)
        #expect(manager.storageError != nil)
        // Storage back: the revocation lands, the error clears.
        store.failsWrites = false
        await manager.tick()
        #expect(store.record?.isRevoked == true)
        #expect(manager.storageError == nil)
        #expect(manager.state == .revoked)
    }

    @Test("P0-2. The same key answered valid:false shows revoked; only a new 201 unlocks")
    func sameKeyInvalidShowsRevokedUntilANewActivation() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .keyDisabledOrExpired)
        #expect(manager.state == .revoked)
        #expect(store.record?.isRevoked == true)
        // "Activate again" with a refused answer keeps the Mac locked.
        client.activation = .keyDisabledOrExpired
        #expect(await manager.activate(key: "KEY-PAID") == .keyDisabledOrExpired)
        #expect(manager.state == .revoked)
        client.activation = .unreachable
        #expect(await manager.activate(key: "KEY-PAID") == .unreachable)
        #expect(manager.state == .revoked)
        #expect(store.record?.isRevoked == true)
        // A fresh 201 is the only way back.
        client.activation = .activated(activation(Self.paid, instance: "inst_9"))
        #expect(await manager.activate(key: "KEY-PAID") == .activated)
        #expect(manager.state == .licensed)
        #expect(store.record?.instanceID == "inst_9")
        #expect(store.record?.isRevoked == false)
    }

    @Test("T2. A revocation the Keychain refused survives an offline restart")
    func revocationSurvivesRestartWhenSaveFailed() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        let manager = makeManager()
        store.failsWrites = true
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(store.record?.isRevoked == false)
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2)) // the record was at 1
        // Quit before the retry; relaunch offline over the same stores.
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .revoked)
        #expect(!restarted.isFeatureEnabled)
        #expect(restarted.storageError != nil)
        await restarted.checkOnLaunch()
        #expect(restarted.state == .revoked)
        // The Keychain accepts the write later: the journal entry is done.
        store.failsWrites = false
        await restarted.tick()
        #expect(store.record?.isRevoked == true)
        #expect(journal.entries.isEmpty)
        #expect(restarted.storageError == nil)
        // Another restart: revoked from the record itself.
        #expect(makeManager().state == .revoked)
    }

    @Test("T2. A journaled revocation is cleared by valid:true for that activation")
    func journalClearedByValidTrue() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        store.failsWrites = true
        let manager = makeManager()
        #expect(manager.state == .revoked)
        store.failsWrites = false
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(manager.state == .licensed)
        #expect(journal.entries.isEmpty)
        #expect(store.record?.isRevoked == false)
    }

    @Test("T2. A journaled revocation is cleared by a new activation or removal")
    func journalClearedByNewActivationAndRemoval() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        client.activation = .activated(activation(Self.paid, instance: "inst_2"))
        let manager = makeManager()
        #expect(manager.state == .revoked)
        #expect(await manager.activate(key: "KEY-PAID-2") == .activated)
        #expect(journal.entries.isEmpty)
        #expect(manager.state == .licensed)
        journal.entries["inst_2"] = JournalEntry(seq: 2)
        #expect(await manager.removeThisMac() == .removed)
        #expect(journal.entries.isEmpty)
        #expect(makeManager().state == .trialEnded)
    }

    @Test("R2. Remove whose Keychain delete fails keeps the activation dead across a restart")
    func removalDeleteFailureKeepsTombstone() async {
        // The reviewer's sequence: invalid → failing store → Remove succeeds
        // at Dodo but the delete fails → offline restart.
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        let manager = makeManager()
        store.failsWrites = true
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_1"] != nil)
        client.deactivation = .deactivated
        #expect(await manager.removeThisMac() == .storageUnavailable)
        #expect(manager.state == .trialEnded)
        #expect(store.record?.isRevoked == false) // the stale record is still there
        #expect(journal.entries["inst_1"] != nil) // and still tombstoned
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(!restarted.isFeatureEnabled)
        #expect(restarted.state == .revoked)
        await restarted.checkOnLaunch()
        #expect(!restarted.isFeatureEnabled)
        // The delete goes through later in the first process: tombstone gone.
        store.failsWrites = false
        await manager.tick()
        #expect(store.record == nil)
        #expect(journal.entries.isEmpty)
        #expect(manager.storageError == nil)
    }

    @Test("R2. Remove that deletes durably clears the tombstone at once")
    func removalClearsTombstoneWhenDurable() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.deactivation = .deactivated
        let manager = makeManager()
        #expect(await manager.removeThisMac() == .removed)
        #expect(store.record == nil)
        #expect(journal.entries.isEmpty)
    }

    @Test("R2. Replacement by a new activation clears the old tombstone only once the new record is stored")
    func replacementClearsTombstoneAfterDurableReplace() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        client.activation = .activated(activation(Self.paid, instance: "inst_2"))
        store.failsWrites = true
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID-2") == .storageFailed)
        #expect(journal.entries["inst_1"] != nil) // nothing replaced: still dead
        #expect(manager.state == .revoked)
        store.failsWrites = false
        #expect(await manager.activate(key: "KEY-PAID-2") == .activated)
        #expect(journal.entries.isEmpty)
        #expect(store.record?.instanceID == "inst_2")
    }

    @Test("R3. A journal that cannot be written keeps the lock, reports it and retries")
    func journalWriteFailureIsReportedAndRetried() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .invalid
        journal.failsWrites = true
        store.failsWrites = true
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .revoked) // locked in memory regardless
        #expect(manager.journalError)
        #expect(journal.entries.isEmpty)
        #expect(manager.nextCheckDelay == LicenseManager.cleanupRetryInterval)
        journal.failsWrites = false
        client.validation = .unreachable
        await manager.tick()
        #expect(journal.entries["inst_1"] != nil)
        #expect(!manager.journalError)
        // The Keychain still refuses: the journal now protects the restart.
        #expect(makeManager().state == .revoked)
    }

    @Test("R3. A journal clear that fails is retried, and never blocks the grant meanwhile")
    func journalClearFailureIsRetried() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.failsWrites = true
        let manager = makeManager()
        #expect(manager.state == .revoked)
        #expect(store.record?.isRevoked == true) // durable, so the entry is due to go
        #expect(manager.journalError) // ... but could not be cleared
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(manager.state == .licensed)
        #expect(manager.journalError)
        #expect(journal.entries["inst_1"] != nil) // stale: the saved record is past it
        // A restart with the stale entry: the newer grant wins and the entry goes.
        journal.failsWrites = false
        let restarted = makeManager()
        #expect(restarted.state == .licensed)
        #expect(journal.entries.isEmpty)
        // And in the first process the retry clears it too.
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        await manager.tick()
        #expect(journal.entries.isEmpty)
        #expect(!manager.journalError)
    }

    @Test("R3. A stale journal entry never overrides a record that has caught up")
    func staleJournalEntryIsIgnored() async {
        store.record = paidRecord(lastSuccessAge: 3600) // eventSeq 1
        journal.entries["inst_1"] = JournalEntry(seq: 1)
        let manager = makeManager()
        #expect(manager.state == .licensed)
        #expect(journal.entries.isEmpty)
        // An entry the record has not reached does win.
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        #expect(makeManager().state == .revoked)
    }

    // MARK: F1 — staleness by event sequence, never by clocks

    @Test("F1. A server clock 60 s ahead cannot make a genuine revocation look stale")
    func serverAheadKeepsRevocation() async {
        var record = paidRecord(lastSuccessAge: 0)
        record.lastSuccessAt = clock.now.addingTimeInterval(60) // server Date ran ahead of this Mac
        record.lastObservedAt = record.lastSuccessAt
        store.record = record
        client.validation = .invalid
        let manager = makeManager()
        store.failsWrites = true
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2))
        #expect(store.record?.isRevoked == false)
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .revoked)
        await restarted.checkOnLaunch()
        #expect(!restarted.isFeatureEnabled)
    }

    @Test("F1. A server clock 60 s behind cannot lock a paid Mac after a newer valid:true")
    func serverBehindDoesNotLockAGrant() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = JournalEntry(seq: 2) // a genuine, recent revocation
        store.failsWrites = true // ... whose record could not be saved
        let manager = makeManager()
        #expect(manager.state == .revoked)
        // Dodo says valid again, with a Date 60 s behind this Mac; the record
        // saves now, the journal clear fails.
        store.failsWrites = false
        journal.failsWrites = true
        client.validation = .valid(serverDate: clock.now.addingTimeInterval(-60))
        await manager.check()
        #expect(manager.state == .licensed)
        #expect(store.record?.eventSeq == 3)
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2))
        // Offline restart: the saved record is past the entry, so it is stale.
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .licensed)
        await restarted.checkOnLaunch()
        #expect(restarted.isFeatureEnabled)
    }

    @Test("F1. valid:true whose save fails leaves the restart locked until the next successful check")
    func grantSaveFailureStaysLocked() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        store.failsWrites = true
        let manager = makeManager()
        #expect(manager.state == .revoked)
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(manager.state == .revoked) // the grant is saved first: not saved, not granted
        #expect(manager.storageError == .unavailable("denied"))
        #expect(manager.failedChecks == 1) // tried again with backoff
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2)) // not cleared: nothing durable moved past it
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .revoked) // fail closed
        store.failsWrites = false
        client.validation = .valid(serverDate: clock.now)
        await restarted.check()
        #expect(restarted.state == .licensed)
        #expect(journal.entries.isEmpty)
        #expect(makeManager().state == .licensed)
    }

    @Test("F1. Old records and time-based entries migrate: honored once, then caught up")
    func legacyEntryMigrates() async {
        var old = paidRecord(lastSuccessAge: 3600)
        old.eventSeq = 0 // saved before the sequence existed
        store.record = old
        journal.entries["inst_1"] = .legacy
        let manager = makeManager()
        #expect(manager.state == .revoked)
        #expect(store.record?.eventSeq == 1)
        #expect(store.record?.isRevoked == true)
        #expect(journal.entries.isEmpty) // durable: caught up
        // A time-based entry against a record that already carries the
        // sequence is stale: the record has moved past it.
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_1"] = .legacy
        #expect(makeManager().state == .licensed)
        #expect(journal.entries.isEmpty)
    }

    @Test("F1. A journal that cannot be read keeps the core off and is left alone")
    func unreadableJournalFailsClosed() async {
        store.record = paidRecord(lastSuccessAge: 60)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.readError = .corrupt
        client.validation = .unreachable
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.journalUnreadable)
        #expect(manager.storageError == .corrupt)
        #expect(manager.nextCheckDelay != nil)
        await manager.check()
        #expect(!manager.isFeatureEnabled) // offline: nothing settles it
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2)) // never overwritten
        // Readable again: the entry decides.
        journal.readError = nil
        await manager.tick()
        #expect(!manager.journalUnreadable)
        #expect(manager.state == .revoked) // the entry (seq 2) is past the record (seq 1)
    }

    @Test("F1. A queued clear never removes a newer revocation")
    func queuedClearCannotRemoveANewerRevocation() async {
        // The sibling app's repro: valid:true saves, the journal clear fails
        // and queues; valid:false then writes a newer entry while its
        // Keychain save fails; the old clear retry must not delete it.
        store.record = paidRecord(lastSuccessAge: 3600) // seq 1
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        store.failsWrites = true
        let manager = makeManager()
        #expect(manager.state == .revoked)
        store.failsWrites = false
        journal.failsWrites = true
        client.validation = .valid(serverDate: clock.now)
        await manager.check() // record seq 3 saved; clear(upTo 3) fails and waits
        #expect(manager.state == .licensed)
        #expect(store.record?.eventSeq == 3)
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2))
        journal.failsWrites = false
        store.failsWrites = true
        client.validation = .invalid
        await manager.check() // entry seq 4 written; the revoked record cannot be saved
        #expect(manager.state == .revoked)
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 4))
        await manager.tick() // whatever is still queued runs now
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 4)) // the older clear could not touch it
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .revoked)
        await restarted.checkOnLaunch()
        #expect(!restarted.isFeatureEnabled)
    }

    @Test("F1. An older record never downgrades a newer journal entry")
    func olderRecordDoesNotDowngrade() {
        journal.entries["inst_1"] = JournalEntry(seq: 9)
        #expect(journal.record(instanceID: "inst_1", entry: JournalEntry(seq: 3)))
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 9))
        #expect(journal.clear(instanceID: "inst_1", upTo: 8))
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 9))
    }

    @Test("F1. An unreadable journal is settled by Dodo, not by waiting: valid:true rebuilds and unlocks")
    func unreadableJournalIsSettledByAValidation() async {
        store.record = paidRecord(lastSuccessAge: 60)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.readError = .corrupt
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        #expect(manager.isCheckDue) // right away, whatever the daily schedule says
        // Offline: stays locked, keeps retrying.
        client.validation = .unreachable
        await manager.tick()
        #expect(manager.state == .checkRequired)
        #expect(manager.nextCheckDelay == 60)
        // "Try again" online, and Dodo says valid: the journal is rebuilt
        // without the unreadable entry and the Mac unlocks at once.
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(manager.state == .licensed)
        #expect(manager.isFeatureEnabled)
        #expect(!manager.journalUnreadable)
        #expect(journal.entries.isEmpty)
        #expect(store.record?.eventSeq == 2)
        journal.readError = nil
        #expect(makeManager().state == .licensed)
    }

    @Test("F1. An unreadable journal settled by valid:false records the revocation")
    func unreadableJournalSettledByInvalid() async {
        store.record = paidRecord(lastSuccessAge: 60)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.readError = .corrupt
        client.validation = .invalid
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(!manager.journalUnreadable)
        #expect(store.record?.isRevoked == true) // durable, so the fresh entry already went again
        #expect(journal.entries.isEmpty)
        journal.readError = nil
        #expect(makeManager().state == .revoked)
        // With the Keychain refusing, the fresh revocation entry is what protects the restart.
        store.record = paidRecord(lastSuccessAge: 60)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.readError = .corrupt
        store.failsWrites = true
        let locked = makeManager()
        await locked.check()
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2))
        journal.readError = nil
        #expect(makeManager().state == .revoked)
    }

    // MARK: G1–G3 — recovery from an unreadable journal

    @Test("G1. A failed recovery clear never outranks a later revocation")
    func failedRecoveryClearDoesNotOutrankALaterRevocation() async {
        // Record seq 1 protected by an unreadable entry. valid:true queues a
        // failed rebuild while the Keychain refuses; invalid then journals
        // seq 3; once the journal writes again, the retry must not erase it.
        store.record = paidRecord(lastSuccessAge: 60)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.unreadable = ["inst_1"]
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        journal.failsWrites = true
        client.validation = .valid(serverDate: clock.now)
        await manager.check() // the grant saves (seq 2); the journal rebuild fails and waits
        #expect(manager.state == .checkRequired) // the rebuild is not durable: still restricted
        #expect(manager.journalError)
        store.failsWrites = true
        client.validation = .invalid
        await manager.check() // revocation seq 3: journaled (fails, waits), Keychain refuses
        #expect(manager.state == .revoked)
        journal.failsWrites = false
        await manager.tick() // the newest request (the revocation) runs, not the stale rebuild
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 3))
        #expect(!journal.unreadable.contains("inst_1"))
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .revoked)
        await restarted.checkOnLaunch()
        #expect(!restarted.isFeatureEnabled)
    }

    @Test("G2. A new paid activation is not locked by the old activation's unreadable journal")
    func newActivationIsNotLockedByOldUnreadableJournal() async {
        store.record = paidRecord(lastSuccessAge: 60)
        journal.unreadable = ["inst_1"]
        client.activation = .activated(activation(Self.paid, instance: "inst_new"))
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        #expect(await manager.activate(key: "KEY-PAID-2") == .activated)
        #expect(manager.state == .licensed)
        #expect(manager.isFeatureEnabled)
        #expect(!manager.journalUnreadable)
        #expect(store.record?.instanceID == "inst_new")
        #expect(manager.nextCheckDelay == LicensePolicy.checkInterval)
        // The old activation's unreadable entry is left alone; it is not
        // this activation's business.
        #expect(journal.unreadable.contains("inst_1"))
    }

    @Test("G2. A new activation whose own journal entry is unreadable is restricted until Dodo settles it")
    func newActivationWithUnreadableEntryIsRestricted() async {
        journal.unreadable = ["inst_new"]
        client.activation = .activated(activation(Self.paid, instance: "inst_new"))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .activated)
        #expect(manager.state == .checkRequired)
        #expect(manager.isCheckDue)
        #expect(manager.nextCheckDelay == 0)
        client.validation = .valid(serverDate: clock.now)
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(!journal.unreadable.contains("inst_new"))
    }

    @Test("G2. Being due means the next timer is now")
    func dueMeansNow() {
        store.record = paidRecord(lastSuccessAge: 25 * 3600)
        let manager = makeManager()
        #expect(manager.isCheckDue)
        #expect(manager.nextCheckDelay == 0)
    }

    @Test("G3. Recovery with valid:false keeps the unreadable protection until the revocation is durable")
    func recoveryWithInvalidIsAtomic() async {
        store.record = paidRecord(lastSuccessAge: 60)
        journal.entries["inst_1"] = JournalEntry(seq: 2)
        journal.unreadable = ["inst_1"]
        let manager = makeManager()
        // The replacement write fails and so does the Keychain save.
        journal.failsWrites = true
        store.failsWrites = true
        client.validation = .invalid
        await manager.check()
        #expect(manager.state == .revoked)
        #expect(journal.unreadable.contains("inst_1")) // still protecting
        #expect(manager.journalError)
        client.validation = .unreachable
        let restarted = makeManager()
        #expect(restarted.state == .checkRequired)
        #expect(!restarted.isFeatureEnabled)
        await restarted.checkOnLaunch()
        #expect(!restarted.isFeatureEnabled)
        // The journal takes the replacement later: the revocation is durable there.
        journal.failsWrites = false
        await manager.tick()
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2))
        #expect(!journal.unreadable.contains("inst_1"))
        #expect(makeManager().state == .revoked)
    }

    @Test("G3. Recovery with valid:true replaces the unreadable entry atomically")
    func recoveryWithValidIsAtomic() async {
        store.record = paidRecord(lastSuccessAge: 60)
        journal.unreadable = ["inst_1"]
        let manager = makeManager()
        journal.failsWrites = true
        client.validation = .valid(serverDate: clock.now)
        await manager.check()
        #expect(manager.state == .checkRequired) // restricted until the rebuild is durable
        #expect(journal.unreadable.contains("inst_1")) // replacement not durable: still there
        #expect(manager.journalUnreadable)
        #expect(makeManager().state == .checkRequired)
        journal.failsWrites = false
        await manager.tick()
        #expect(!journal.unreadable.contains("inst_1"))
        #expect(journal.entries["inst_1"] == nil)
        #expect(!manager.journalUnreadable)
        #expect(manager.state == .licensed) // lifted by the durable rebuild, no new check needed
        #expect(makeManager().state == .licensed)
    }

    @Test("F4. A new activation after a failed delete clears the old tombstone too")
    func replacementAfterFailedDeleteClearsOldTombstone() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.deactivation = .deactivated
        let manager = makeManager()
        store.failsWrites = true
        #expect(await manager.removeThisMac() == .storageUnavailable)
        #expect(journal.entries["inst_1"] == JournalEntry(seq: 2))
        store.failsWrites = false
        client.activation = .activated(activation(Self.paid, instance: "inst_2"))
        #expect(await manager.activate(key: "KEY-PAID-2") == .activated)
        #expect(journal.entries.isEmpty)
        #expect(store.record?.instanceID == "inst_2")
        await manager.tick()
        #expect(store.record?.instanceID == "inst_2") // the owed delete never hits the new record
        #expect(manager.state == .licensed)
        #expect(manager.storageError == nil)
    }

    @Test("T2. The journal never wins over a different activation")
    func journalIsPerActivation() {
        store.record = paidRecord(lastSuccessAge: 3600)
        journal.entries["inst_other"] = JournalEntry(seq: 5)
        #expect(makeManager().state == .licensed)
    }

    @Test("P0-2. Remove this Mac that cannot be saved stays removed in memory and is retried")
    func removalWriteFailureIsRetried() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        let manager = makeManager()
        store.failsWrites = true
        #expect(await manager.removeThisMac() == .storageUnavailable)
        #expect(manager.state == .trialEnded)
        #expect(store.record != nil)
        store.failsWrites = false
        await manager.tick()
        #expect(store.record == nil)
        #expect(manager.storageError == nil)
    }
}
