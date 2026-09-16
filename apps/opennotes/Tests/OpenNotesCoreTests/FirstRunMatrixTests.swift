import Foundation
@testable import OpenNotesCore
import Testing

/// `Tests/OpenNotesCoreTests/FirstRunTests.swift` (XCTest) already ports
/// macPaper's `OnboardingLaunchTests` and `FreshInstallDefaultMatrixTests`
/// case by case, including the evidence-list and fresh-install-defaults
/// matrix in full. The only gap found against macPaper's Swift Testing
/// originals: `testStepsAreInGuideOrder` checks `welcome.next`,
/// `permissions.next` and `tips.previous`, but never exercises OpenNotes'
/// extra `.files` step (absent from macPaper's four-step guide) in either
/// direction. These two checks close that gap; nothing else was missing.
@Suite("Guide step order — the .files step macPaper does not have")
struct GuideStepOrderTests {
    @Test func filesStepsForwardToLoginItem() {
        #expect(GuideStep.files.next == .loginItem)
    }

    @Test func loginItemStepsBackToFiles() {
        #expect(GuideStep.loginItem.previous == .files)
    }
}
