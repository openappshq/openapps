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

    final class FakeClient: LicenseClient, @unchecked Sendable {
        enum Call: Equatable { case activate(key: String, name: String), validate, deactivate(instance: String) }
        var calls: [Call] = []
        var activation: ActivationResult = .unreachable
        var validation: ValidationResult = .unreachable
        var deactivation: DeactivationResult = .deactivated

        func activate(licenseKey: String, name: String) async -> ActivationResult {
            calls.append(.activate(key: licenseKey, name: name))
            return activation
        }

        func validate(licenseKey: String, instanceID: String) async -> ValidationResult {
            calls.append(.validate)
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
        func loadRecord() -> LicenseRecord? { record }
        func saveRecord(_ record: LicenseRecord) { self.record = record }
        func clearRecord() { record = nil }
        func markTrialUsed() { trialUsed = true }
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
        #expect(client.calls == [.validate])
        #expect(store.record?.lastSuccessAt == clock.now)
        // Not due again until tomorrow.
        #expect(!manager.isCheckDue)
        #expect(manager.nextCheckDelay == LicensePolicy.checkInterval)
        #expect(await manager.checkIfDue() == false)
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

    @Test("11. Clock rollback does not extend grace")
    func case11_clockRollback() {
        store.record = paidRecord(lastSuccessAge: 3 * Clock.day)
        clock.advance(-5 * Clock.day) // local clock now 2 days before last_success_at
        let manager = makeManager()
        #expect(manager.state == .checkRequired)
        #expect(manager.isCheckDue)
        #expect(!manager.isFeatureEnabled)
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

    @Test("Failed checks back off from 1 minute to 1 hour")
    func backoff() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        client.validation = .unreachable
        let manager = makeManager()
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            manager_clearBlock(manager)
            await manager.check()
            delays.append(manager.nextCheckDelay ?? -1)
        }
        #expect(delays == [60, 120, 240, 480, 960, 1920, 3600, 3600])
        // While blocked by backoff, checkIfDue makes no call.
        let calls = client.calls.count
        #expect(await manager.checkIfDue() == false)
        #expect(client.calls.count == calls)
        // Once the backoff elapses, the retry is due even if the day is not over.
        clock.advance(3600)
        #expect(manager.isCheckDue)
    }

    private func manager_clearBlock(_ manager: LicenseManager) {
        if let delay = manager.nextCheckDelay { clock.advance(delay) }
    }

    @Test("One check at a time")
    func oneCheckAtATime() async {
        store.record = paidRecord(lastSuccessAge: 2 * Clock.day)
        client.validation = .valid(serverDate: nil)
        let manager = makeManager()
        async let first: Void = manager.check()
        async let second: Void = manager.check()
        _ = await (first, second)
        #expect(client.calls.count == 1)
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
        #expect(LicenseMessage.trialAlreadyUsed.text == "The trial was already used on this Mac.")
        #expect(client.calls.isEmpty)
        // Even if a trial key is pasted into the key field, it is not kept.
        let message = await manager.activate(key: "KEY-TRIAL-2")
        #expect(message == .trialAlreadyUsed)
        #expect(store.record == nil)
        #expect(client.calls.last == .deactivate(instance: "inst_t2"))
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
