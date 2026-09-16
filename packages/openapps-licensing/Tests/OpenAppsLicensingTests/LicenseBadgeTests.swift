import Foundation
import OpenAppsLicensing
import Testing

@Suite("License badge")
struct LicenseBadgeTests {
    @Test func trialCountsDownAndSaysLessThanADayOnTheLastDay() {
        #expect(LicenseBadge.label(for: .trial(daysLeft: 3), appName: "OpenReaction") == .init(text: "Free trial · 3 days left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 2), appName: "OpenReaction") == .init(text: "Free trial · 2 days left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 1), appName: "OpenReaction") == .init(text: "Free trial · less than a day left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 0), appName: "OpenReaction")?.text == "Free trial · less than a day left")
    }

    @Test func trialEnded() {
        #expect(LicenseBadge.label(for: .trialEnded, appName: "OpenReaction") == .init(text: "Trial ended", tone: .attention))
    }

    @Test func licensedShowsNothing() {
        #expect(LicenseBadge.label(for: .licensed, appName: "OpenReaction") == nil)
        #expect(LicenseBadge.label(for: .grace(daysLeft: 3, showWarning: false), appName: "OpenReaction") == nil)
    }

    @Test func restrictedStatesShowTheShortReason() {
        #expect(LicenseBadge.label(for: .trialNeedsConnection, appName: "OpenReaction") == .init(text: "Connect to the internet to continue your free trial", tone: .attention))
        #expect(LicenseBadge.label(for: .trialClockBehind, appName: "OpenReaction") == .init(text: "Your Mac’s clock is behind", tone: .attention))
        #expect(LicenseBadge.label(for: .checkRequired, appName: "OpenReaction") == .init(text: "Connect to the internet to verify your license", tone: .attention))
        #expect(LicenseBadge.label(for: .revoked, appName: "OpenReaction") == .init(text: "License no longer active on this Mac", tone: .attention))
        #expect(LicenseBadge.label(for: .grace(daysLeft: 1, showWarning: true), appName: "OpenReaction") == .init(text: "Connect to the internet within 1 day to keep using OpenReaction", tone: .attention))
        #expect(LicenseBadge.label(for: .grace(daysLeft: 2, showWarning: true), appName: "OpenReaction")?.text == "Connect to the internet within 2 days to keep using OpenReaction")
    }

    @Test func unavailableSaysStartingUnlessStorageFailed() {
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: "OpenReaction") == .init(text: "Starting your free trial…", tone: .trial))
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: "OpenReaction", storageError: true) == .init(text: "Can’t read the license record", tone: .attention))
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: "OpenReaction", trialStorageError: true) == .init(text: "Can’t read or save the free trial record", tone: .attention))
        #expect(LicenseBadge.label(for: .trialUnavailable, appName: "OpenReaction", storageError: true, trialStorageError: true)?.text == "Can’t read the license record")
    }

    @Test func onlyFeatureOnStatesAreCalm() {
        let states: [LicenseState] = [
            .trialUnavailable, .trial(daysLeft: 2), .trialNeedsConnection, .trialClockBehind, .trialEnded,
            .licensed, .grace(daysLeft: 6, showWarning: false), .grace(daysLeft: 1, showWarning: true), .checkRequired, .revoked,
        ]
        for state in states {
            guard let label = LicenseBadge.label(for: state, appName: "OpenReaction") else {
                #expect(state.isFeatureEnabled, "only licensed states hide the badge: \(state)")
                continue
            }
            if !state.isFeatureEnabled, state != .trialUnavailable {
                #expect(label.tone == .attention, "\(state)")
            }
        }
    }
}
