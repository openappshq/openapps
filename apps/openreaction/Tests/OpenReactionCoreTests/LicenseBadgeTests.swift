import Foundation
import OpenReactionCore
import Testing

@Suite("License badge")
struct LicenseBadgeTests {
    @Test func trialCountsDownAndSaysLessThanADayOnTheLastDay() {
        #expect(LicenseBadge.label(for: .trial(daysLeft: 3)) == .init(text: "Free trial · 3 days left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 2)) == .init(text: "Free trial · 2 days left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 1)) == .init(text: "Free trial · less than a day left", tone: .trial))
        #expect(LicenseBadge.label(for: .trial(daysLeft: 0))?.text == "Free trial · less than a day left")
    }

    @Test func trialEnded() {
        #expect(LicenseBadge.label(for: .trialEnded) == .init(text: "Trial ended", tone: .attention))
    }

    @Test func licensedShowsNothing() {
        #expect(LicenseBadge.label(for: .licensed) == nil)
        #expect(LicenseBadge.label(for: .grace(daysLeft: 3, showWarning: false)) == nil)
    }

    @Test func restrictedStatesShowTheShortReason() {
        #expect(LicenseBadge.label(for: .trialNeedsConnection) == .init(text: "Connect to the internet to continue your free trial", tone: .attention))
        #expect(LicenseBadge.label(for: .trialClockBehind) == .init(text: "Your Mac’s clock is behind", tone: .attention))
        #expect(LicenseBadge.label(for: .checkRequired) == .init(text: "Connect to the internet to verify your license", tone: .attention))
        #expect(LicenseBadge.label(for: .revoked) == .init(text: "License no longer active on this Mac", tone: .attention))
        #expect(LicenseBadge.label(for: .grace(daysLeft: 1, showWarning: true)) == .init(text: "Connect to the internet within 1 day to keep using OpenReaction", tone: .attention))
        #expect(LicenseBadge.label(for: .grace(daysLeft: 2, showWarning: true))?.text == "Connect to the internet within 2 days to keep using OpenReaction")
    }

    @Test func unavailableSaysStartingUnlessStorageFailed() {
        #expect(LicenseBadge.label(for: .trialUnavailable) == .init(text: "Starting your free trial…", tone: .trial))
        #expect(LicenseBadge.label(for: .trialUnavailable, storageError: true) == .init(text: "Can’t read the license from the Keychain", tone: .attention))
        #expect(LicenseBadge.label(for: .trialUnavailable, trialStorageError: true) == .init(text: "Can’t read or save the free trial in the Keychain", tone: .attention))
        #expect(LicenseBadge.label(for: .trialUnavailable, storageError: true, trialStorageError: true)?.text == "Can’t read the license from the Keychain")
    }

    @Test func onlyFeatureOnStatesAreCalm() {
        let states: [LicenseState] = [
            .trialUnavailable, .trial(daysLeft: 2), .trialNeedsConnection, .trialClockBehind, .trialEnded,
            .licensed, .grace(daysLeft: 6, showWarning: false), .grace(daysLeft: 1, showWarning: true), .checkRequired, .revoked,
        ]
        for state in states {
            guard let label = LicenseBadge.label(for: state) else {
                #expect(state.isFeatureEnabled, "only licensed states hide the badge: \(state)")
                continue
            }
            if !state.isFeatureEnabled, state != .trialUnavailable {
                #expect(label.tone == .attention, "\(state)")
            }
        }
    }
}
