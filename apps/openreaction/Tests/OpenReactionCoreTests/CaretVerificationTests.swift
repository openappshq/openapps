import OpenReactionCore
import Testing

@Suite("Caret verification")
struct CaretVerificationTests {
    private func decide(
        typed: String, selection: (location: Int, length: Int)?, before: String? = nil
    ) -> VerifyDecision {
        CaretVerification.decide(
            typedCount: typed.utf16.count, selection: selection, typed: typed, readBefore: { before }
        )
    }

    @Test func unreadableSelectionFallsBack() {
        #expect(decide(typed: ":tada", selection: nil) == .unverifiable)
    }

    @Test func bogusZeroAnswerWithAHeldTokenFallsBack() {
        // A field the user just typed ":tada" into cannot really be empty at
        // caret 0: {0,0} is a bogus AX answer, so fall back rather than refuse.
        #expect(decide(typed: ":tada", selection: (location: 0, length: 0)) == .unverifiable)
    }

    @Test func realMismatchStillRefuses() {
        // Text "ab" before the caret cannot hold a 5-unit token: a real
        // mismatch (the field genuinely is shorter), not the bogus zero case.
        #expect(decide(typed: ":tada", selection: (location: 2, length: 0), before: "ab") == .refused)
    }

    @Test func aRealSelectionRefuses() {
        #expect(decide(typed: ":tada", selection: (location: 5, length: 3), before: ":tada") == .refused)
    }

    @Test func differingTextBeforeTheCaretRefuses() {
        #expect(decide(typed: ":tada", selection: (location: 5, length: 0), before: "hello") == .refused)
    }

    @Test func unreadableTextBeforeAReadableCaretFallsBack() {
        // Selection readable, room for the token, but the text itself opaque.
        #expect(decide(typed: ":tada", selection: (location: 5, length: 0), before: nil) == .unverifiable)
    }

    @Test func matchingTextBeforeTheCaretIsVerified() {
        #expect(decide(typed: ":tada", selection: (location: 5, length: 0), before: ":tada") == .keystrokes)
    }
}
