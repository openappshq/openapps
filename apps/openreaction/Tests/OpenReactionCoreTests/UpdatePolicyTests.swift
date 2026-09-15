import Foundation
import OpenReactionCore
import Testing

@Suite struct UpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freshInstallNeverChecksOnItsOwn() {
        #expect(UpdatePolicy.automaticChecksByDefault == false)
        #expect(UpdatePolicy.automaticDownloadsByDefault == false)
        #expect(!UpdatePolicy.isAutomaticCheckDue(
            automaticChecks: UpdatePolicy.automaticChecksByDefault, location: .updatable, lastCheck: nil, now: now))
    }

    @Test func automaticChecksRunWhenNeverCheckedOrADayHasPassed() {
        #expect(UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: nil, now: now))
        #expect(UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: now.addingTimeInterval(-86_399), now: now))
    }

    @Test func aLastCheckInTheFutureIsDue() {
        #expect(UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: now.addingTimeInterval(3_600), now: now))
    }

    @Test func turnedOffOrNotUpdatableNeverChecks() {
        let old = now.addingTimeInterval(-10 * 86_400)
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: false, location: .updatable, lastCheck: old, now: now))
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .translocated, lastCheck: old, now: now))
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .readOnly, lastCheck: nil, now: now))
    }

    @Test func retriesOnceAfterAnHourThenWaitsForTheDailyCheck() {
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 0) == nil)
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 1) == 3_600)
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 2) == nil)
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 7) == nil)
    }

    @Test func classifiesLocations() {
        #expect(UpdateLocation.classify(bundlePath: "/Users/a/Applications/OpenReaction.app", volumeIsReadOnly: false, containerIsWritable: true) == .updatable)
        #expect(UpdateLocation.classify(
            bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/OpenReaction.app", volumeIsReadOnly: true, containerIsWritable: false) == .translocated)
        #expect(UpdateLocation.classify(bundlePath: "/Volumes/OpenReaction/OpenReaction.app", volumeIsReadOnly: true, containerIsWritable: false) == .readOnly)
        #expect(UpdateLocation.classify(bundlePath: "/Applications/OpenReaction.app", volumeIsReadOnly: false, containerIsWritable: false) == .readOnly)
    }
}
