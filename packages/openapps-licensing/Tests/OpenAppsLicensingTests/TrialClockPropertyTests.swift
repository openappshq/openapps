import Foundation
import OpenAppsLicensing
import Testing

/// Random sequences of wall-clock jumps, monotonic advances, sleeps, save
/// failures, registry answers and relaunches against the trial clock.
extension LicensingTests {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * Double(next() >> 11) / Double(1 << 53)
        }
    }

    @Test("Property: out-of-order observations never move the trial clock; in-order ones never lower it or count twice", arguments: Array(UInt64(1)...40))
    func trialClockRejectsOutOfOrderObservations(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        let hour: TimeInterval = 3600
        var wall = Date(timeIntervalSince1970: 1_800_000_000)
        var mono: TimeInterval = 10_000
        var clock = TrialClock(seen: wall, at: TrialObservation(wall: wall, mono: mono))
        var history = [clock.anchor]
        var bound = wall // the most `seen` can be without counting anything twice
        var violations: [String] = []
        for step in 0..<500 {
            let before = clock
            switch rng.next() % 6 {
            case 0, 1: // a stale moment, captured before a wait that later observations overtook
                let stale = history[Int(rng.next() % UInt64(history.count))]
                guard stale.mono < clock.anchor.mono else { continue }
                clock.observe(stale, checkingBehind: rng.next() % 2 == 0)
                if clock != before { violations.append("step \(step): an out-of-order observation changed the clock") }
                continue
            case 2: // the wall clock jumps; a little monotonic time passes
                let moved = rng.uniform(0...60)
                mono += moved
                wall = wall.addingTimeInterval(rng.uniform(-3 * 86_400 ... 6 * hour))
                bound = max(bound.addingTimeInterval(moved), wall)
            default: // time passes, with the wall clock following or stuck
                let moved = rng.uniform(1...2 * hour)
                mono += moved
                if rng.next() % 2 == 0 { wall = wall.addingTimeInterval(moved) }
                bound = max(bound.addingTimeInterval(moved), wall)
            }
            let observation = TrialObservation(wall: wall, mono: mono)
            clock.observe(observation, checkingBehind: rng.next() % 4 == 0)
            history.append(observation)
            if clock.seen < before.seen { violations.append("step \(step): seen went down") }
            if clock.anchor.mono < before.anchor.mono { violations.append("step \(step): the anchor moved backwards") }
            if clock.seen > bound.addingTimeInterval(0.001) { violations.append("step \(step): time counted twice") }
        }
        #expect(violations.isEmpty, "seed \(seed): \(violations.prefix(3))")
    }

    @Test("Property: trial time never goes down, is never counted twice, and access never outlasts 24 h / 72 h of monotonic time", arguments: Array(UInt64(1)...40))
    func trialClockProperty(seed: UInt64) async {
        var rng = SplitMix64(state: seed)
        let hour: TimeInterval = 3600
        let maxStep = 3 * hour
        trialStore.record = nil
        let startMono = clock.uptime
        let registryEpoch = Date(timeIntervalSince1970: 1_700_000_000) // the registry's own clock
        var online = false
        var manager = makeManager()
        await manager.checkOnLaunch()

        var violations: [String] = []
        var bound = clock.now // the most `seen` can be without counting anything twice
        var seenInProcess = manager.trial?.lastSeenAt ?? .distantPast
        var stored = trialStore.record
        var access: TimeInterval = 0
        var unregisteredAccess: TimeInterval = 0
        var relaunches = 0
        /// Monotonic time the trial must have counted: everything except
        /// intervals that began with the clock found behind.
        var countable: TimeInterval = 0

        // Long enough that every sequence runs well past the 24 h and 72 h
        // limits on the monotonic clock.
        for step in 0..<400 {
            registry.result = online
                ? .registered(startedAt: registryEpoch, now: registryEpoch.addingTimeInterval(clock.uptime - startMono))
                : .unreachable
            let before = manager.snapshot
            let wasRegistered = manager.trial?.registered ?? false
            let wasOn = before.state(now: clock.now, uptime: clock.uptime).isFeatureEnabled
            let startedBehind = before.trialClock?.isBehind(at: TrialObservation(wall: clock.now, mono: clock.uptime)) ?? false
            var moved: TimeInterval = 0
            switch rng.next() % 10 {
            case 0, 1, 2: // time passes normally
                moved = rng.uniform(300...2 * hour)
                clock.advance(moved)
                await manager.tick()
            case 3: // the wall clock is stuck
                moved = rng.uniform(300...2 * hour)
                clock.uptime += moved
                await manager.tick()
            case 4: // the wall clock jumps while running
                clock.now = clock.now.addingTimeInterval(rng.uniform(-3 * 86_400 ... 6 * hour))
                await manager.tick()
            case 5: // sleep, with the wall clock following or stuck, then wake
                moved = rng.uniform(600...maxStep)
                if rng.next() % 2 == 0 { clock.advance(moved) } else { clock.uptime += moved }
                await manager.wake()
            case 6:
                trialStore.failsWrites.toggle()
                await manager.tick()
            case 7:
                online.toggle()
                registry.result = online
                    ? .registered(startedAt: registryEpoch, now: registryEpoch.addingTimeInterval(clock.uptime - startMono))
                    : .unreachable
                await manager.tick(wake: true)
            case 8: // a clean quit and relaunch
                guard relaunches < 3, !manager.trialClockBehind else { continue }
                trialStore.failsWrites = false
                await manager.tick()
                manager.saveTrialBeforeQuit()
                manager = makeManager()
                await manager.checkOnLaunch()
                relaunches += 1
                seenInProcess = manager.trial?.lastSeenAt ?? seenInProcess
            default: // the clock is set right
                clock.now = max(clock.now, bound)
                await manager.tick()
            }

            bound = max(bound.addingTimeInterval(moved), clock.now)
            if let trial = manager.trial {
                if trial.lastSeenAt < seenInProcess { violations.append("step \(step): last_seen_at went down") }
                if trial.lastSeenAt > bound.addingTimeInterval(0.001) {
                    violations.append("step \(step): last_seen_at \(trial.lastSeenAt) passed \(bound): time counted twice")
                }
                seenInProcess = trial.lastSeenAt
            }
            if let saved = trialStore.record, let previous = stored {
                if saved.lastSeenAt < previous.lastSeenAt { violations.append("step \(step): saved last_seen_at went down") }
                if saved.startedAt > previous.startedAt { violations.append("step \(step): saved start moved later") }
            }
            stored = trialStore.record ?? stored

            // Never loses time: outside a clock found behind, both the manager
            // and the snapshot enforcement held count every monotonic second,
            // whatever the wall clock did.
            if moved > 0, !startedBehind { countable += moved }
            if let elapsed = manager.trialElapsed, elapsed + 1 < countable {
                violations.append("step \(step): elapsed \(elapsed / hour) h is short of \(countable / hour) h of monotonic time")
            }
            if moved > 0, !startedBehind, let heldClock = before.trialClock, let heldTrial = before.trial {
                let projected = heldClock.projectedSeen(at: TrialObservation(wall: clock.now, mono: clock.uptime))
                    .timeIntervalSince(heldTrial.startedAt)
                if projected + 1 < countable {
                    violations.append("step \(step): enforcement projected \(projected / hour) h, short of \(countable / hour) h")
                }
            }

            // What enforcement allowed over the step, from the snapshot it held.
            let isOn = before.state(now: clock.now, uptime: clock.uptime).isFeatureEnabled
            if moved > 0, wasOn || isOn {
                access += moved
                if !wasRegistered { unregisteredAccess += moved }
            }
            // Boundary steps are counted whole; a relaunch may lose an unsaved hour.
            let allowance = 3 * maxStep + Double(relaunches) * hour
            if access > 3 * 86_400 + allowance { violations.append("step \(step): \(access / hour) h of access") }
            if unregisteredAccess > 86_400 + allowance {
                violations.append("step \(step): \(unregisteredAccess / hour) h of unregistered access")
            }
        }
        #expect(violations.isEmpty, "seed \(seed): \(violations.prefix(3))")
    }
}
