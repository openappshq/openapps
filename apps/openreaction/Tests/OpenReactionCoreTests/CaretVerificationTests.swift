import OpenReactionCore
import Testing

@Suite("Caret verification")
struct CaretVerificationTests {
    private let textField = AXStringAnswer.value("AXTextField")

    private func decide(
        role: AXStringAnswer = .value("AXTextField"),
        subrole: AXStringAnswer = .absent,
        typed: String = ":tada",
        selection: (location: Int, length: Int)?,
        text: @escaping (Int, Int) -> String? = { _, _ in nil }
    ) -> VerifyDecision {
        CaretVerification.decide(
            role: role, subrole: subrole, typedCount: typed.utf16.count,
            selection: selection, typed: typed, textBeforeCaret: text
        )
    }

    // MARK: Secure

    @Test func aPositivelySecureSubroleRefusesEvenIfTextMatches() {
        // A password field never gets typed into, whatever else reads back.
        let decision = decide(subrole: .value("AXSecureTextField"), selection: (5, 0)) { _, _ in ":tada" }
        #expect(decision == .refused)
    }

    // MARK: Verified path (role/subrole not required — the text is read back)

    @Test func matchingTextBeforeTheCaretIsVerifiedRegardlessOfRole() {
        let decision = decide(role: .unreadable, subrole: .unreadable, selection: (5, 0)) { loc, len in
            loc == 0 && len == 5 ? ":tada" : nil
        }
        #expect(decision == .keystrokes)
    }

    // MARK: Real mismatches → refused

    @Test func aRealSelectionRefuses() {
        #expect(decide(selection: (5, 3)) { _, _ in ":tada" } == .refused)
    }

    @Test func tooLittleRoomBeforeTheCaretRefuses() {
        // Caret at 2, a 5-unit token cannot fit: a real mismatch.
        #expect(decide(selection: (2, 0)) { _, _ in "ab" } == .refused)
    }

    @Test func differingTextBeforeTheCaretRefuses() {
        #expect(decide(selection: (5, 0)) { _, _ in "hello" } == .refused)
    }

    // MARK: Fallback candidates need a positively readable text field

    @Test func opaqueSelectionFallsBackForAReadableTextField() {
        #expect(decide(role: textField, subrole: .absent, selection: nil) == .unverifiable)
        #expect(decide(role: textField, subrole: .value("AXSearchField"), selection: nil) == .unverifiable)
    }

    @Test func opaqueSelectionRefusesWhenTheSubroleIsUnreadable() {
        // The P0: an unreadable subrole must not authorize typing into an
        // opaque field (it could be a password field that hides its subrole).
        #expect(decide(role: textField, subrole: .unreadable, selection: nil) == .refused)
    }

    @Test func opaqueSelectionRefusesWhenTheRoleIsUnreadable() {
        #expect(decide(role: .unreadable, subrole: .absent, selection: nil) == .refused)
    }

    @Test func opaqueSelectionRefusesForANonTextRole() {
        #expect(decide(role: .value("AXButton"), subrole: .absent, selection: nil) == .refused)
    }

    @Test func unreadableTextBeforeAReadableCaretFallsBackForATextField() {
        // Selection readable with room, but the text opaque.
        #expect(decide(role: textField, subrole: .absent, selection: (5, 0)) { _, _ in nil } == .unverifiable)
        // …and refuses when the field is not a positively readable text field.
        #expect(decide(role: .unreadable, subrole: .absent, selection: (5, 0)) { _, _ in nil } == .refused)
    }

    // MARK: The bogus {0,0} case

    @Test func bogusZeroCaretWithReadableEmptyBeforeTextFallsBack() {
        let decision = decide(role: textField, subrole: .absent, selection: (0, 0)) { loc, len in
            loc == 0 && len == 0 ? "" : nil
        }
        #expect(decision == .unverifiable)
    }

    @Test func bogusZeroCaretWithUnreadableBeforeTextFallsBackConservatively() {
        // Unreadable before-text at caret 0 is still opaque → fallback, but only
        // because the role/subrole positively classify it as a text field.
        #expect(decide(role: textField, subrole: .absent, selection: (0, 0)) { _, _ in nil } == .unverifiable)
        #expect(decide(role: .unreadable, subrole: .absent, selection: (0, 0)) { _, _ in nil } == .refused)
    }

    @Test func zeroCaretWithMalformedNonEmptyZeroRangeRefuses() {
        // A non-empty answer for a zero-length range is malformed, not the
        // bogus-zero case.
        let decision = decide(role: textField, subrole: .absent, selection: (0, 0)) { _, _ in "x" }
        #expect(decision == .refused)
    }

    // MARK: Probe secure mapping (shared with CaretLocator's fail-closed probe)

    @Test func isSecureMapsEveryAnswerState() {
        #expect(CaretVerification.isSecure(subrole: .value("AXSecureTextField")) == true)
        #expect(CaretVerification.isSecure(subrole: .value("AXTextField")) == false)
        #expect(CaretVerification.isSecure(subrole: .absent) == false)
        #expect(CaretVerification.isSecure(subrole: .unreadable) == nil) // fail-closed
    }
}
