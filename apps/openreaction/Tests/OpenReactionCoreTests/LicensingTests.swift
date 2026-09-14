import Foundation
import OpenReactionCore
import Testing

/// The shared test cases from LICENSING.md, numbered as there, against a
/// fake Dodo client and an injectable clock.
@Suite("Licensing")
@MainActor
struct LicensingTests {
    static let paid = "pdt_openreaction_PAID"
    static let trial = "pdt_openreaction_TRIAL"
    static let other = "pdt_openklack_PAID"
    static let products = LicenseProducts(paid: [paid], trial: [trial])

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
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
        var trialUsed = false
        var failsWrites = false
        var failsReads = false
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
        func loadTrialUsed() throws(LicenseStoreError) -> Bool {
            if failsReads { throw .unavailable("locked") }
            return trialUsed
        }
        func markTrialUsed() throws(LicenseStoreError) {
            if failsWrites { throw .unavailable("denied") }
            trialUsed = true
        }
    }

    let clock = Clock()
    let client = FakeClient()
    let store = MemoryStore()

    private func makeManager() -> LicenseManager {
        LicenseManager(products: Self.products, client: client, store: store, now: { self.clock.now })
    }

    private func activation(_ product: String, name: String = "OpenReaction", instance: String = "inst_1") -> Activation {
        Activation(instanceID: instance, productID: product, productName: name, createdAt: clock.now, serverDate: clock.now)
    }

    /// A paid record whose last success was `age` seconds ago.
    private func paidRecord(lastSuccessAge age: TimeInterval) -> LicenseRecord {
        LicenseRecord(
            licenseKey: "KEY-PAID", instanceID: "inst_1", productID: Self.paid, kind: .paid,
            activatedAt: clock.now.addingTimeInterval(-30 * Clock.day), lastSuccessAt: clock.now.addingTimeInterval(-age)
        )
    }

    private func trialRecord(activatedAge age: TimeInterval) -> LicenseRecord {
        LicenseRecord(
            licenseKey: "KEY-TRIAL", instanceID: "inst_t", productID: Self.trial, kind: .trial,
            activatedAt: clock.now.addingTimeInterval(-age), lastSuccessAt: clock.now.addingTimeInterval(-age)
        )
    }

    // MARK: Activation

    @Test("1. Paid key activates and is stored")
    func case1_paidKeyActivates() async {
        client.activation = .activated(activation(Self.paid))
        let manager = makeManager()
        let message = await manager.activate(key: " KEY-PAID\n")
        #expect(message == .activated(.paid))
        #expect(manager.state == .licensed)
        #expect(manager.isFeatureEnabled)
        #expect(store.record?.kind == .paid)
        #expect(store.record?.licenseKey == "KEY-PAID")
        #expect(store.record?.instanceID == "inst_1")
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac")])
    }

    @Test("2. Another app's key is deactivated again and nothing is saved")
    func case2_foreignKeyIsRefused() async {
        client.activation = .activated(activation(Self.other, name: "OpenKlack", instance: "inst_x"))
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-X")
        #expect(message == .wrongProduct(productName: "OpenKlack"))
        #expect(message.text == "This key is for OpenKlack, not OpenReaction.")
        #expect(store.record == nil)
        #expect(manager.state == .unlicensed)
        #expect(client.calls == [.activate(key: "KEY-X", name: "Mac"), .deactivate(instance: "inst_x")])
    }

    @Test("3. Activation limit reached")
    func case3_limitReached() async {
        client.activation = .activationLimitReached
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .allMacsActivated)
        #expect(message.text.contains("All 3 Macs"))
        #expect(manager.state == .unlicensed)
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
        #expect(manager.state == .unlicensed)
        #expect(store.record == nil)
    }

    @Test("5. Activation timeout saves nothing")
    func case5_timeout() async {
        client.activation = .unreachable
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .unreachable)
        #expect(message.text.hasPrefix("Couldn’t reach the license service"))
        #expect(manager.state == .unlicensed)
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

    @Test("L3. Clock rollback cannot extend a trial")
    func trialClockRollback() {
        var record = trialRecord(activatedAge: 2 * Clock.day)
        record.lastObservedAt = clock.now
        store.record = record
        clock.advance(-30 * Clock.day)
        let manager = makeManager()
        #expect(manager.state == .trial(daysLeft: 1))
        clock.advance(31 * Clock.day)
        #expect(manager.state == .trialEnded)
    }

    @Test("L3. Time observed by the app is remembered so rollback later changes nothing")
    func noteTimeRaisesTheHighWaterMark() {
        store.record = trialRecord(activatedAge: Clock.day)
        let manager = makeManager()
        clock.advance(1.5 * Clock.day)
        manager.noteTime()
        #expect(store.record?.lastObservedAt == clock.now)
        clock.advance(-10 * Clock.day)
        #expect(manager.state == .trial(daysLeft: 1))
    }

    @Test("L3. Deadlines are local and independent of the network schedule")
    func localDeadlines() {
        store.record = trialRecord(activatedAge: 3 * Clock.day - 2.4 * 3600)
        var manager = makeManager()
        #expect(manager.nextDeadline == clock.now.addingTimeInterval(2.4 * 3600))
        #expect(manager.nextCheckDelay == 0) // never attempted: launch check
        store.record = paidRecord(lastSuccessAge: 3600)
        manager = makeManager()
        // Daily due, then the five-day warning, then the end of grace.
        #expect(manager.nextDeadline == clock.now.addingTimeInterval(LicensePolicy.checkInterval - 3600))
        clock.advance(2 * Clock.day)
        #expect(manager.nextDeadline == clock.now.addingTimeInterval(LicensePolicy.graceWarningAfter - 2 * Clock.day - 3600))
        clock.advance(4 * Clock.day)
        #expect(manager.nextDeadline == clock.now.addingTimeInterval(LicensePolicy.graceDuration - 6 * Clock.day - 3600))
        clock.advance(2 * Clock.day)
        #expect(manager.nextDeadline == nil)
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

    @Test("L1. A late trial valid:true cannot overwrite a paid upgrade")
    func lateTrialValidDoesNotOverwritePaid() async {
        store.record = trialRecord(activatedAge: Clock.day)
        store.trialUsed = true
        let gate = Gate()
        client.validationGate = gate
        client.validation = .valid(serverDate: nil)
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let pendingCheck = Task { await manager.check() }
        await Task.yield()
        let pendingActivate = Task { await manager.activate(key: "KEY-PAID") }
        await Task.yield()
        await gate.release()
        await pendingCheck.value
        #expect(await pendingActivate.value == .activated(.paid))
        #expect(store.record?.kind == .paid)
        #expect(store.record?.instanceID == "inst_p")
        #expect(manager.state == .licensed)
    }

    @Test("L1. A late valid:false revokes the old record, not the new paid one")
    func lateInvalidDoesNotRevokeNewRecord() async {
        store.record = trialRecord(activatedAge: Clock.day)
        store.trialUsed = true
        let gate = Gate()
        client.validationGate = gate
        client.validation = .invalid
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let pendingCheck = Task { await manager.check() }
        await Task.yield()
        let pendingActivate = Task { await manager.activate(key: "KEY-PAID") }
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
        #expect(manager.state == .unlicensed)
        #expect(store.record == nil)
    }

    // MARK: Trial

    @Test("12. Trial key starts a trial and marks the Mac")
    func case12_trialActivates() async {
        client.activation = .activated(activation(Self.trial, name: "OpenReaction Trial", instance: "inst_t"))
        let manager = makeManager()
        #expect(!manager.refusesTrialLocally)
        let message = await manager.activate(key: "KEY-TRIAL")
        #expect(message == .activated(.trial))
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(manager.isFeatureEnabled)
        #expect(store.trialUsed)
        #expect(store.record?.kind == .trial)
    }

    @Test("13. Trial older than 3 days has ended, offline or not")
    func case13_trialExpiresLocally() {
        store.record = trialRecord(activatedAge: 3 * Clock.day + 60)
        store.trialUsed = true
        let manager = makeManager()
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
        #expect(client.calls.isEmpty)
    }

    @Test("Trial days left count down")
    func trialDaysLeft() {
        store.record = trialRecord(activatedAge: 1.5 * Clock.day)
        let manager = makeManager()
        #expect(manager.state == .trial(daysLeft: 2))
        clock.advance(1.4 * Clock.day)
        #expect(manager.state == .trial(daysLeft: 1))
    }

    @Test("14. valid:false ends the trial")
    func case14_trialRevoked() async {
        store.record = trialRecord(activatedAge: Clock.day)
        store.trialUsed = true
        client.validation = .invalid
        let manager = makeManager()
        await manager.check()
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
    }

    @Test("15. A second trial is refused without calling Dodo")
    func case15_secondTrialRefusedLocally() async {
        store.trialUsed = true
        client.activation = .activated(activation(Self.trial, instance: "inst_t2"))
        let manager = makeManager()
        #expect(manager.refusesTrialLocally)
        // The trial route (Start 3-day trial, or a trial deep link) is refused
        // locally: Dodo is never called.
        let message = await manager.activate(key: "KEY-TRIAL-2", expecting: .trial)
        #expect(message == .trialAlreadyUsed)
        #expect(message.text == "The trial was already used on this Mac.")
        #expect(client.calls.isEmpty)
        #expect(store.record == nil)
    }

    @Test("A trial key pasted into the plain key field is activated, then released (keys are opaque)")
    func trialKeyInPlainFieldIsReleased() async {
        store.trialUsed = true
        client.activation = .activated(activation(Self.trial, instance: "inst_t2"))
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-TRIAL-2")
        #expect(message == .trialAlreadyUsed)
        #expect(store.record == nil)
        #expect(client.calls == [.activate(key: "KEY-TRIAL-2", name: "Mac"), .deactivate(instance: "inst_t2")])
    }

    @Test("16. Buying during a trial licenses the Mac and frees the trial activation")
    func case16_paidDuringTrial() async {
        store.record = trialRecord(activatedAge: Clock.day)
        store.trialUsed = true
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .activated(.paid))
        #expect(manager.state == .licensed)
        #expect(store.record?.kind == .paid)
        #expect(store.trialUsed)
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac"), .deactivate(instance: "inst_t")])
    }

    // MARK: L4 — storage failures

    @Test("L4. A record that cannot be saved is not announced; the activation is released")
    func storageFailureReleasesActivation() async {
        store.failsWrites = true
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        let message = await manager.activate(key: "KEY-PAID")
        #expect(message == .storageFailed)
        #expect(manager.state == .unlicensed)
        #expect(store.record == nil)
        #expect(client.calls == [.activate(key: "KEY-PAID", name: "Mac"), .deactivate(instance: "inst_p")])
    }

    @Test("L4. A trial that cannot be saved does not consume the trial or retire anything")
    func trialStorageFailureKeepsTrialAvailable() async {
        store.failsWrites = true
        client.activation = .activated(activation(Self.trial, instance: "inst_t"))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-TRIAL") == .storageFailed)
        #expect(!store.trialUsed)
        #expect(store.record == nil)
        #expect(client.calls.last == .deactivate(instance: "inst_t"))
    }

    @Test("L4. Buying during a trial keeps the trial if the paid record cannot be saved")
    func paidDuringTrialStorageFailureKeepsTrial() async {
        store.record = trialRecord(activatedAge: Clock.day)
        store.trialUsed = true
        store.failsWrites = true
        client.activation = .activated(activation(Self.paid, instance: "inst_p"))
        let manager = makeManager()
        #expect(await manager.activate(key: "KEY-PAID") == .storageFailed)
        #expect(store.record?.kind == .trial)
        #expect(manager.state == .trial(daysLeft: 2))
        #expect(!client.calls.contains(.deactivate(instance: "inst_t")))
    }

    @Test("L4. Unreadable storage is reported, not treated as unlicensed silently")
    func unreadableStorageIsReported() {
        store.failsReads = true
        let manager = makeManager()
        #expect(manager.storageError == .unavailable("locked"))
        #expect(manager.state == .unlicensed)
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
        #expect(await manager.activate(key: "KEY-PAID-2") == .activated(.paid))
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

    // MARK: Removal

    @Test("17. Remove this Mac clears everything but trial_used")
    func case17_removeThisMac() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        store.trialUsed = true
        client.deactivation = .deactivated
        let manager = makeManager()
        #expect(await manager.removeThisMac() == .removed)
        #expect(manager.state == .unlicensed)
        #expect(store.record == nil)
        #expect(store.trialUsed)
        #expect(client.calls == [.deactivate(instance: "inst_1")])
    }

    @Test("18. Remove this Mac offline keeps the license")
    func case18_removeOffline() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.deactivation = .unreachable
        let manager = makeManager()
        let message = await manager.removeThisMac()
        #expect(message == .removeFailedOffline)
        #expect(manager.state == .licensed)
        #expect(store.record != nil)
    }

    // MARK: Rate limit and build flavour

    @Test("19. 429 blocks calls for Retry-After and changes nothing")
    func case19_rateLimited() async {
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

    @Test("20. Source builds have no licensing: feature on, no calls")
    func case20_sourceBuild() {
        // A build without OPENAPPS_LICENSING never creates a manager.
        let manager: LicenseManager? = nil
        #expect(LicenseGate.isFeatureEnabled(manager))
        #expect(client.calls.isEmpty)
    }

    // MARK: Policy details

    @Test("Record round-trips through Codable")
    func recordRoundTrip() throws {
        let record = paidRecord(lastSuccessAge: 10)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(LicenseRecord.self, from: data) == record)
    }

    @Test("Revoked record can be forgotten to start over")
    func forgetRevoked() async {
        store.record = paidRecord(lastSuccessAge: 10)
        client.validation = .invalid
        let manager = makeManager()
        await manager.check()
        manager.forgetRevokedRecord()
        #expect(manager.state == .unlicensed)
        #expect(store.record == nil)
    }
}
