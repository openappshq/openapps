import Foundation
import OpenReactionCore
import Testing

/// Shared test cases 12–27 from LICENSING.md (the in-app trial and the
/// trial registry), with the same fakes as cases 1–11.
extension LicensingTests {
    typealias Day = Clock

    /// Lets a concurrent operation reach its network call.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }

    private var hardwareHash: String {
        TrialDevice.hash(app: LicenseManager.trialAppID, hardwareID: device.uuid!)
    }

    // MARK: 12–15 — starting, ending, elapsed time

    @Test("12. A fresh Mac saves a provisional trial, turns the core on before any answer, then registers")
    func case12_freshMacStartsAndRegisters() async {
        trialStore.record = nil
        // The registry's clock is 7 h off this Mac's; only its difference counts.
        let registryNow = clock.now.addingTimeInterval(7 * 3600)
        registry.result = .registered(startedAt: registryNow, now: registryNow)
        let gate = Gate()
        registry.gate = gate
        let manager = makeManager()
        #expect(trialStore.saves == [TrialRecord(startedAt: clock.now, lastSeenAt: clock.now, registered: false)])
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(manager.isFeatureEnabled)
        #expect(registry.devices.isEmpty) // launch never waits for the network
        #expect(manager.nextCheckDelay == 0) // registration is due at once

        let launch = Task { await manager.checkOnLaunch() }
        await until { registry.devices.count == 1 }
        #expect(manager.isFeatureEnabled) // on while the registry has not answered
        await gate.release()
        await launch.value
        #expect(registry.devices == [hardwareHash])
        #expect(trialStore.record == TrialRecord(startedAt: clock.now, lastSeenAt: clock.now, registered: true))
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(client.calls.isEmpty) // no license: no Dodo calls at all

        // A registered trial never contacts the registry again.
        clock.advance(3600)
        await manager.tick(wake: true)
        await manager.checkOnLaunch()
        #expect(registry.devices.count == 1)
    }

    @Test("13. A registered trial past 3 days has ended at launch, with no network calls", arguments: [false, true])
    func case13_endedTrialAtLaunch(online: Bool) async {
        trialStore.record = trialRecord(elapsed: 3 * Day.day + 60)
        registry.result = online ? .registered(startedAt: clock.now, now: clock.now) : .unreachable
        let manager = makeManager()
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
        await manager.checkOnLaunch()
        await manager.tick(wake: true)
        #expect(manager.state == .trialEnded)
        #expect(registry.devices.isEmpty)
        #expect(client.calls.isEmpty)
        #expect(manager.nextCheckDelay == nil)
    }

    @Test("14. A clock set back 5 days at relaunch: core off with \"clock is behind\", nothing saved; corrected, Trial with 1 day left")
    func case14_clockSetBack() async {
        trialStore.record = trialRecord(elapsed: 2 * Day.day)
        #expect(makeManager().state == .trial(daysLeft: 1))
        clock.advance(-5 * Day.day)
        let relaunched = makeManager()
        #expect(relaunched.state == .trialClockBehind)
        #expect(!relaunched.isFeatureEnabled)
        #expect(relaunched.nextDeadline == Clock.start.addingTimeInterval(-3600))
        await relaunched.checkOnLaunch()
        for _ in 0..<3 {
            clock.uptime += 3600 // the app keeps running with the clock still wrong
            await relaunched.tick()
        }
        relaunched.saveTrialBeforeQuit()
        #expect(relaunched.state == .trialClockBehind)
        #expect(trialStore.saves.isEmpty) // nothing saved
        #expect(relaunched.trial?.lastSeenAt == Clock.start) // no time added, trial not ended
        // Corrected to within the hour: back on, with the day that was left.
        clock.now = Clock.start.addingTimeInterval(-30 * 60)
        #expect(relaunched.state == .trial(daysLeft: 1))
        await relaunched.tick()
        #expect(!relaunched.trialClockBehind)
        #expect(relaunched.state == .trial(daysLeft: 1))
        #expect(relaunched.trial?.elapsed(now: clock.now) == 2 * Day.day)
    }

    @Test("28. A frozen or set-back wall clock does not pause a running trial: monotonic time ends it", arguments: [0, -2 * 3600] as [TimeInterval])
    func case28_monotonicTimeKeepsCounting(wallChange: TimeInterval) async {
        trialStore.record = trialRecord(elapsed: Day.day)
        let manager = makeManager()
        clock.now = clock.now.addingTimeInterval(wallChange) // frozen from here on
        for hour in 1...48 {
            clock.uptime += 3600
            await manager.tick()
            if hour == 24 {
                #expect(manager.state == .trial(daysLeft: 1))
                // The end is a day of observed time away: the timer is armed for it.
                #expect(manager.nextDeadline == clock.now.addingTimeInterval(Day.day))
            }
        }
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.trial?.lastSeenAt == Clock.start.addingTimeInterval(2 * Day.day))
        #expect(trialStore.record?.lastSeenAt == Clock.start.addingTimeInterval(2 * Day.day)) // saved at the end
        #expect(!manager.trialClockBehind) // running, not launched or woken
    }

    @Test("A clock found behind on wake turns the core off until it is within the hour; running without a wake keeps counting")
    func clockBehindOnWake() async {
        trialStore.record = trialRecord(elapsed: Day.day)
        let manager = makeManager()
        clock.now = clock.now.addingTimeInterval(-3 * 3600)
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 2)) // no wake: not checked
        await manager.wake()
        #expect(manager.state == .trialClockBehind)
        #expect(!manager.isFeatureEnabled)
        clock.advance(2.5 * 3600) // within the hour again
        #expect(manager.state == .trial(daysLeft: 2))
        await manager.tick()
        #expect(!manager.trialClockBehind)
        #expect(manager.trial?.lastSeenAt == Clock.start) // the time behind added nothing
    }

    @Test("15. The core switches off on time, from memory, while saves fail and the registry is down")
    func case15_endsOnTime() async {
        trialStore.record = trialRecord(elapsed: 3 * Day.day - 60)
        let manager = makeManager()
        let snapshot = manager.snapshot
        #expect(snapshot.state(now: clock.now) == .trial(daysLeft: 1))
        #expect(snapshot.nextDeadline == clock.now.addingTimeInterval(60))
        trialStore.failsWrites = true
        clock.advance(120)
        // A snapshot taken before the deadline already knows: no I/O involved.
        #expect(snapshot.state(now: clock.now) == .trialEnded)
        #expect(manager.state == .trialEnded)
        await manager.tick() // the end-of-trial save fails; the state does not care
        #expect(manager.state == .trialEnded)
        #expect(manager.trialStorageError == .unavailable("denied"))
        #expect(manager.nextCheckDelay == LicensePolicy.minimumRetryDelay)
        trialStore.failsWrites = false
        await manager.tick()
        #expect(trialStore.record?.lastSeenAt == clock.now)
        #expect(manager.trialStorageError == nil)
    }

    @Test("Remaining time is shown in whole days, rounded up; the final day is less than a day")
    func remainingDays() {
        trialStore.record = trialRecord(elapsed: 0)
        let manager = makeManager()
        #expect(manager.state == .trial(daysLeft: 3))
        clock.advance(Day.day + 1)
        #expect(manager.state == .trial(daysLeft: 2))
        clock.advance(Day.day)
        #expect(manager.state == .trial(daysLeft: 1))
        #expect(manager.nextDeadline == trialStore.record!.startedAt.addingTimeInterval(3 * Day.day))
    }

    // MARK: 16–17 — storage

    @Test("16. A provisional trial that cannot be saved does not run, and is retried")
    func case16_provisionalSaveFails() async {
        trialStore.record = nil
        trialStore.failsWrites = true
        let manager = makeManager()
        #expect(manager.state == .trialUnavailable)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.trialStorageError == .unavailable("denied"))
        #expect(manager.trial == nil)
        #expect(manager.nextCheckDelay == LicensePolicy.minimumRetryDelay)
        await manager.checkOnLaunch()
        await manager.tick()
        #expect(manager.state == .trialUnavailable)
        #expect(registry.devices.isEmpty) // no trial running: nothing to register
        // Each retry (load, then every tick) reads again before it writes.
        #expect(trialStore.loads == 2)
        #expect(trialStore.saves.isEmpty)
        trialStore.failsWrites = false
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(manager.trialStorageError == nil)
        #expect(trialStore.record?.registered == false)
        #expect(registry.devices.count == 1)
    }

    @Test("17. An unreadable trial record is a storage error: no new trial, no registry call, nothing overwritten", arguments: [
        LicenseStoreError.unavailable("locked"), LicenseStoreError.corrupt,
    ])
    func case17_unreadableTrialRecord(error: LicenseStoreError) async {
        trialStore.record = trialRecord(elapsed: 12 * 3600, registered: false)
        let existing = trialStore.record
        trialStore.readError = error
        let manager = makeManager()
        #expect(manager.state == .trialUnavailable)
        #expect(!manager.isFeatureEnabled)
        #expect(manager.trialStorageError == error)
        await manager.checkOnLaunch()
        await manager.tick()
        await manager.tick(wake: true)
        manager.saveTrialBeforeQuit()
        #expect(manager.state == .trialUnavailable)
        #expect(registry.devices.isEmpty)
        #expect(trialStore.saves.isEmpty)
        #expect(trialStore.record == existing)
        // Readable again: the stored record decides.
        trialStore.readError = nil
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 3)) // 12 h used
        #expect(trialStore.record?.startedAt == existing?.startedAt)
        #expect(registry.devices.count == 1) // and now it may register
    }

    // MARK: 18–21 — the registry

    @Test("18. After a Keychain wipe the registry's older start ends the trial")
    func case18_wipedRegistryEndsTrial() async {
        trialStore.record = nil
        let registryNow = clock.now.addingTimeInterval(-3 * 3600) // its clock runs 3 h behind
        registry.result = .registered(startedAt: registryNow.addingTimeInterval(-4 * Day.day), now: registryNow)
        let manager = makeManager()
        #expect(manager.state == .trial(daysLeft: 3)) // provisional
        let seen = Snapshots()
        manager.setOnChange { seen.append($0) }
        trialStore.failsWrites = true // the save after the answer fails ...
        await manager.checkOnLaunch()
        #expect(manager.state == .trialEnded) // ... and access is removed anyway, in memory first
        #expect(!manager.isFeatureEnabled)
        #expect(seen.all.contains { $0.trial?.registered == true && $0.state(now: clock.now) == .trialEnded })
        #expect(trialStore.record?.registered == false)
        #expect(manager.trialStorageError != nil)
        trialStore.failsWrites = false
        await manager.tick()
        #expect(trialStore.record?.registered == true)
        #expect(trialStore.record?.startedAt == clock.now.addingTimeInterval(-4 * Day.day))
        #expect(registry.devices.count == 1)
    }

    @Test("19. After a Keychain wipe the registry's start 1 day ago leaves 2 days, not 3")
    func case19_wipedRegistryKeepsRemainingTime() async {
        trialStore.record = nil
        registry.result = .registered(startedAt: clock.now.addingTimeInterval(-Day.day), now: clock.now)
        let manager = makeManager()
        await manager.checkOnLaunch()
        #expect(manager.state == .trial(daysLeft: 2))
        #expect(manager.isFeatureEnabled)
        #expect(trialStore.record == TrialRecord(startedAt: clock.now.addingTimeInterval(-Day.day), lastSeenAt: clock.now, registered: true))
    }

    @Test("20. An unregistered trial runs 24 h offline, then waits for the registry, whose answer restores the right time")
    func case20_offlineLimit() async {
        trialStore.record = nil
        registry.result = .unreachable
        let manager = makeManager()
        await manager.checkOnLaunch()
        for _ in 0..<23 {
            clock.advance(3600)
            await manager.tick()
        }
        #expect(manager.state == .trial(daysLeft: 3)) // 23 h
        #expect(manager.isFeatureEnabled)
        #expect(manager.nextDeadline == Clock.start.addingTimeInterval(Day.day))
        clock.advance(3600) // 24 h
        #expect(manager.state == .trialNeedsConnection)
        #expect(!manager.isFeatureEnabled)
        clock.advance(3600) // 25 h
        await manager.tick()
        #expect(manager.state == .trialNeedsConnection)
        #expect(trialStore.record?.lastSeenAt == clock.now) // raised while waiting, too

        // The registry answers (it has never seen this Mac): turning the
        // core back on is saved first; a refused save grants nothing.
        registry.result = .registered(startedAt: clock.now, now: clock.now)
        trialStore.failsWrites = true
        await manager.tick(wake: true)
        #expect(manager.state == .trialNeedsConnection)
        #expect(trialStore.record?.registered == false)
        #expect(manager.trialStorageError == .unavailable("denied"))
        trialStore.failsWrites = false
        await manager.tick(wake: true)
        #expect(manager.state == .trial(daysLeft: 2)) // 25 h used of 72
        #expect(manager.isFeatureEnabled)
        #expect(manager.trialStorageError == nil)
        #expect(trialStore.record?.registered == true)
        #expect(trialStore.record?.startedAt == Clock.start) // the earlier, provisional start
    }

    @Test("29. A registration that extends a running trial is saved before it counts: it still stops at 24 h while the save fails")
    func case20_extensionSavedFirst() async {
        trialStore.record = trialRecord(elapsed: 23 * 3600, registered: false)
        registry.result = .registered(startedAt: clock.now, now: clock.now) // the registry agrees on the start
        let manager = makeManager()
        let seen = Snapshots()
        manager.setOnChange { seen.append($0) }
        trialStore.failsWrites = true
        await manager.checkOnLaunch()
        #expect(registry.devices.count == 1)
        #expect(manager.trial?.registered == false) // not published: not saved
        #expect(!seen.all.contains { $0.trial?.registered == true })
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(manager.trialStorageError == .unavailable("denied"))
        #expect(manager.nextCheckDelay == LicensePolicy.minimumRetryDelay)
        clock.advance(2 * 3600) // 25 h: the provisional limit still applies
        #expect(manager.state == .trialNeedsConnection)
        #expect(!manager.isFeatureEnabled)
        await manager.tick()
        #expect(manager.state == .trialNeedsConnection)
        #expect(registry.devices.count == 1) // the answer is kept, not asked for again
        trialStore.failsWrites = false
        await manager.tick()
        #expect(manager.state == .trial(daysLeft: 2))
        #expect(manager.isFeatureEnabled)
        #expect(trialStore.record?.registered == true)
        #expect(trialStore.record?.startedAt == Clock.start.addingTimeInterval(-23 * 3600))
        #expect(manager.trialStorageError == nil)
        #expect(registry.devices.count == 1)
    }

    @Test("21. Registry 429 Retry-After: 120 blocks calls for 120 s; state unchanged")
    func case21_registryRateLimited() async {
        trialStore.record = trialRecord(elapsed: 3600, registered: false)
        registry.result = .rateLimited(retryAfter: 120)
        let manager = makeManager()
        await manager.checkOnLaunch()
        #expect(registry.devices.count == 1)
        #expect(manager.state == .trial(daysLeft: 3))
        #expect(trialStore.record?.registered == false)
        #expect(manager.nextCheckDelay == 120)
        clock.advance(119)
        await manager.tick()
        await manager.tick(wake: true) // wake skips backoff, never Retry-After
        #expect(registry.devices.count == 1)
        clock.advance(1)
        await manager.tick()
        #expect(registry.devices.count == 2)
    }

    @Test("21. Registry 500 backs off 1 min doubling to 1 h; wake asks at once; state unchanged")
    func case21_registryBacksOff() async {
        trialStore.record = trialRecord(elapsed: 3600, registered: false)
        registry.result = .unreachable
        let manager = makeManager()
        await manager.checkOnLaunch()
        for wait in [60, 120, 240, 480, 960, 1920, 3600, 3600] as [TimeInterval] {
            // The timer is armed no later than the backoff (the hourly
            // last_seen_at save may come first).
            #expect((manager.nextCheckDelay ?? .infinity) <= wait)
            let calls = registry.devices.count
            clock.advance(wait - 1)
            await manager.tick()
            #expect(registry.devices.count == calls) // not before the backoff
            clock.advance(1)
            await manager.tick()
            #expect(registry.devices.count == calls + 1)
        }
        #expect(manager.trial?.registered == false)
        #expect(manager.state == .trial(daysLeft: 3)) // about 4 h used: unchanged by failures
        await manager.tick(wake: true)
        #expect(registry.devices.count == 10)
    }

    @Test("Registry answers decode by the contract")
    func registryResponses() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data(#"{"started_at":"2027-01-15T08:00:00.000Z","now":"2027-01-16T08:00:00Z"}"#.utf8)
        guard case .registered(let started, let serverNow) = TrialRegistryResponse.result(statusCode: 200, retryAfter: nil, body: body, now: now) else {
            Issue.record("expected an answer")
            return
        }
        #expect(serverNow.timeIntervalSince(started) == Day.day)
        #expect(TrialRegistryResponse.result(statusCode: 200, retryAfter: nil, body: Data("{}".utf8)) == .unreachable)
        #expect(TrialRegistryResponse.result(statusCode: 200, retryAfter: nil, body: Data(#"{"started_at":"soon","now":"2027-01-16T08:00:00Z"}"#.utf8)) == .unreachable)
        #expect(TrialRegistryResponse.result(statusCode: 429, retryAfter: "120", body: Data()) == .rateLimited(retryAfter: 120))
        #expect(TrialRegistryResponse.result(statusCode: 429, retryAfter: nil, body: Data()) == .rateLimited(retryAfter: 60))
        #expect(TrialRegistryResponse.result(statusCode: 429, retryAfter: "Fri, 15 Jan 2027 08:02:00 GMT", body: Data(),
                                             now: now) == .rateLimited(retryAfter: 120)) // `now` is 08:00:00 GMT that day
        #expect(TrialRegistryResponse.result(statusCode: 400, retryAfter: nil, body: Data()) == .unreachable)
        #expect(TrialRegistryResponse.result(statusCode: 500, retryAfter: nil, body: Data()) == .unreachable)
        // The request carries exactly app, device and env.
        let request = try #require(JSONSerialization.jsonObject(with: TrialRegistryResponse.requestBody(
            app: "openreaction", device: hardwareHash, environment: "test"
        )) as? [String: String])
        #expect(request == ["app": "openreaction", "device": hardwareHash, "env": "test"])
    }

    @Test("31. A stored record for a retired trial key, or for another product, is not a license: the trial rules apply", arguments: [true, false])
    func nonPaidRecordIsNotALicense(legacyTrialKind: Bool) async throws {
        let paid = paidRecord(lastSuccessAge: 3600)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(paid)) as? [String: Any])
        if legacyTrialKind {
            object["kind"] = "trial" // saved before the trial moved in-app
        } else {
            object["productID"] = Self.retiredTrial
        }
        let stored = try JSONDecoder().decode(LicenseRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(stored.isLegacyTrial == legacyTrialKind)
        store.record = stored
        trialStore.record = trialRecord(elapsed: Day.day)
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        #expect(manager.record == nil)
        #expect(manager.state == .trial(daysLeft: 2))
        #expect(manager.isFeatureEnabled)
        await manager.checkOnLaunch()
        #expect(client.calls.isEmpty) // nothing to check with Dodo
        // With the trial over it is TrialEnded, never Licensed.
        trialStore.record = trialRecord(elapsed: 4 * Day.day)
        #expect(makeManager().state == .trialEnded)
        // A real activation replaces it.
        client.activation = .activated(activation(Self.paid, instance: "inst_new"))
        #expect(await makeManager().activate(key: "KEY-PAID-2") == .activated)
        #expect(store.record?.instanceID == "inst_new")
        #expect(store.record?.isLegacyTrial == false)
    }

    @Test("A Mac with a license never asks the registry, even with an unregistered trial record")
    func licensedMacNeverRegisters() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        trialStore.record = trialRecord(elapsed: 3600, registered: false)
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        await manager.checkOnLaunch()
        await manager.tick(wake: true)
        #expect(manager.state == .licensed)
        #expect(registry.devices.isEmpty)
        #expect(trialStore.saves.isEmpty) // ignored, but kept
        #expect(trialStore.loads == 0) // not even read while licensed
    }

    @Test("An unreadable trial record does not surface while licensed; it is read once the license is removed")
    func unreadableTrialRecordIgnoredWhileLicensed() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        trialStore.readError = .corrupt
        client.validation = .valid(serverDate: clock.now)
        let manager = makeManager()
        await manager.tick()
        #expect(manager.state == .licensed)
        #expect(manager.snapshot.trialStorageError == nil)
        #expect(manager.nextCheckDelay == LicensePolicy.checkInterval) // no trial retries scheduled
        #expect(trialStore.loads == 0)
        #expect(await manager.removeThisMac() == .removed)
        #expect(manager.state == .trialUnavailable)
        #expect(manager.snapshot.trialStorageError == .corrupt)
        #expect(trialStore.saves.isEmpty) // never a new trial over it
    }

    // MARK: Device identity

    @Test("An unreadable hardware UUID uses a random id kept in the trial record")
    func fallbackDeviceID() async throws {
        trialStore.record = nil
        device.uuid = nil
        let manager = makeManager()
        let fallback = try #require(trialStore.record?.fallbackDeviceID)
        #expect(UUID(uuidString: fallback) != nil)
        await manager.checkOnLaunch()
        #expect(registry.devices == [TrialDevice.hash(app: "openreaction", hardwareID: fallback)])
        // Relaunched, still unreadable: the same id, so the same hash.
        let relaunched = makeManager()
        clock.advance(3600)
        await relaunched.tick(wake: true)
        #expect(registry.devices.count == 2)
        #expect(Set(registry.devices).count == 1)
    }

    @Test("30. A fallback id is saved before every registry request that uses it")
    func fallbackDeviceIDSavedFirst() async {
        trialStore.record = trialRecord(elapsed: 3600, registered: false) // made while the UUID was readable
        device.uuid = nil
        trialStore.failsWrites = true
        let manager = makeManager()
        await manager.checkOnLaunch()
        #expect(registry.devices.isEmpty)
        #expect(manager.trialStorageError != nil)
        #expect(manager.state == .trial(daysLeft: 3)) // a failed save never stops the trial
        // The id now sits in memory, but still not in the store: every
        // attempt, however it is prompted, waits for it to be saved.
        #expect(manager.trial?.fallbackDeviceID != nil)
        for _ in 0..<3 {
            clock.advance(3600)
            await manager.tick()
            await manager.tick(wake: true)
        }
        #expect(registry.devices.isEmpty)
        #expect(trialStore.record?.fallbackDeviceID == nil)
        trialStore.failsWrites = false
        clock.advance(60)
        await manager.tick()
        let fallback = trialStore.record?.fallbackDeviceID
        #expect(fallback != nil)
        #expect(registry.devices == [TrialDevice.hash(app: "openreaction", hardwareID: fallback ?? "")])
    }

    // MARK: last_seen_at

    @Test("last_seen_at is raised every tick, saved at most hourly, at the end and on quit")
    func lastSeenSaves() async {
        trialStore.record = trialRecord(elapsed: 3 * Day.day - 90 * 60)
        let manager = makeManager()
        clock.advance(600)
        await manager.tick()
        #expect(manager.trial?.lastSeenAt == clock.now)
        #expect(trialStore.saves.isEmpty)
        clock.advance(3000)
        await manager.tick() // an hour since the record was read
        #expect(trialStore.saves.count == 1)
        #expect(trialStore.record?.lastSeenAt == clock.now)
        clock.advance(60)
        manager.saveTrialBeforeQuit()
        #expect(trialStore.saves.count == 2)
        #expect(trialStore.record?.lastSeenAt == clock.now)
        clock.advance(30 * 60) // 3 days + 1 min: the trial ends and is saved at once, not an hour later
        await manager.tick()
        #expect(manager.state == .trialEnded)
        #expect(trialStore.saves.count == 3)
        #expect(trialStore.record?.lastSeenAt == clock.now)
        // Ended and saved: a relaunch with the clock set back stays ended.
        clock.advance(-2 * Day.day)
        #expect(makeManager().state == .trialEnded)
    }

    // MARK: 22–24 — removing a license

    @Test("22. Remove this Mac after the trial ended: TrialEnded, license cleared, trial record unchanged")
    func case22_removeAfterTrialEnded() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        let trialBefore = trialStore.record
        let manager = makeManager()
        #expect(manager.state == .licensed)
        #expect(await manager.removeThisMac() == .removed)
        #expect(manager.state == .trialEnded)
        #expect(!manager.isFeatureEnabled)
        #expect(store.record == nil)
        #expect(trialStore.record == trialBefore)
        #expect(trialStore.saves.isEmpty)
        #expect(client.calls == [.deactivate(instance: "inst_1")])
        #expect(registry.devices.isEmpty)
    }

    @Test("23. Remove this Mac with 1 day of trial left: back to Trial with 1 day left")
    func case23_removeBackToTrial() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        trialStore.record = trialRecord(elapsed: 2 * Day.day)
        let manager = makeManager()
        #expect(manager.state == .licensed)
        #expect(await manager.removeThisMac() == .removed)
        #expect(manager.state == .trial(daysLeft: 1))
        #expect(manager.isFeatureEnabled)
        #expect(trialStore.record?.startedAt == clock.now.addingTimeInterval(-2 * Day.day)) // never restarted
    }

    @Test("Remove this Mac with no trial record (wiped meanwhile) asks the registry for the original start")
    func removeWithWipedTrialRecord() async {
        store.record = paidRecord(lastSuccessAge: 3600)
        trialStore.record = nil
        registry.result = .registered(startedAt: clock.now.addingTimeInterval(-20 * Day.day), now: clock.now)
        let manager = makeManager()
        #expect(trialStore.saves.isEmpty) // licensed: no trial is started
        #expect(await manager.removeThisMac() == .removed)
        #expect(trialStore.record?.registered == false)
        await manager.tick()
        #expect(manager.state == .trialEnded)
        #expect(trialStore.record?.registered == true)
    }

    // MARK: 27 — the device hash

    @Test("27. One Mac's device hashes differ per app and never contain the hardware UUID")
    func case27_deviceHash() {
        let uuid = "00000000-1111-2222-3333-444444444444"
        let reaction = TrialDevice.hash(app: "openreaction", hardwareID: uuid)
        let klack = TrialDevice.hash(app: "openklack", hardwareID: uuid)
        #expect(reaction != klack)
        #expect(reaction != uuid && klack != uuid)
        #expect(!reaction.localizedCaseInsensitiveContains(uuid) && !klack.localizedCaseInsensitiveContains(uuid))
        #expect(!reaction.contains("00000000") && !reaction.contains("444444444444"))
        for hash in [reaction, klack] {
            #expect(hash.count == 64)
            #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
        }
        // SHA-256 of "openapps-trial-v1:<app>:<uuid>" (checked with `shasum -a 256`).
        #expect(reaction == "3908da30d9e234cb79e2610af64dae33d48e104abf20dc631670ce3fcdcbc2d7")
        #expect(klack == "97a89ea0b23e771bc9038fac3d9b1359a7033eee688f71f46f2e76b81ae41f48")
    }

    final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [LicenseSnapshot] = []
        var all: [LicenseSnapshot] { lock.withLock { snapshots } }
        func append(_ snapshot: LicenseSnapshot) { lock.withLock { snapshots.append(snapshot) } }
    }
}
