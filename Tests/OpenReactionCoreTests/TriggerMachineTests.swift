import OpenReactionCore
import Testing

@Suite("Trigger state machine")
struct TriggerMachineTests {
    private func machine(typing text: String) -> TriggerMachine {
        var machine = TriggerMachine()
        machine.handle(.text(text))
        return machine
    }

    @Test func colonAtStartStartsEmptyToken() {
        let machine = machine(typing: ":")
        #expect(machine.current.token?.query == "")
        #expect(machine.current.token?.typedLength == 1)
    }

    @Test func lettersAfterColonBuildQuery() {
        let machine = machine(typing: ":tada")
        #expect(machine.current.token?.query == "tada")
        #expect(machine.current.token?.typedLength == 5)
    }

    @Test func queryIsLowercased() {
        #expect(machine(typing: ":TaDa").current.token?.query == "tada")
    }

    @Test(arguments: ["hello :smi", "(:smi", "\":smi", "🎉:smi", "line\n:smi", "tab\t:smi"])
    func colonAfterBoundaryTriggers(text: String) {
        #expect(machine(typing: text).current.token?.query == "smi")
    }

    @Test(arguments: ["http://ex", "https:ex", "12:30", "key:value", "C:\\", "a.b:c", "user@host:path", "x_:y", "~:y"])
    func colonGluedToWordDoesNotTrigger(text: String) {
        #expect(machine(typing: text).current.token == nil)
    }

    @Test func shortcodeCharactersIncludeSignsAndUnderscore() {
        #expect(machine(typing: ":+1").current.token?.query == "+1")
        #expect(machine(typing: ":-1").current.token?.query == "-1")
        #expect(machine(typing: ":thumbs_up").current.token?.query == "thumbs_up")
    }

    @Test(arguments: [":tada ", ":tada.", ":)", ":tada!", ":é"])
    func nonShortcodeCharacterEndsToken(text: String) {
        #expect(machine(typing: text).current.token == nil)
    }

    @Test func tooLongQueryEndsToken() {
        var machine = TriggerMachine(maxQueryLength: 5)
        machine.handle(.text(":abcde"))
        #expect(machine.current.token?.query == "abcde")
        machine.handle(.text("f"))
        #expect(machine.current.token == nil)
    }

    @Test func backspaceEditsQuery() {
        var machine = machine(typing: ":tadx")
        let id = machine.current.token?.id
        machine.handle(.backspace)
        #expect(machine.current.token?.query == "tad")
        #expect(machine.current.token?.id == id)
        machine.handle(.text("a"))
        #expect(machine.current.token?.query == "tada")
    }

    @Test func backspaceOverColonEndsToken() {
        var machine = machine(typing: "hi :t")
        machine.handle(.backspace)
        #expect(machine.current.token?.query == "")
        machine.handle(.backspace)
        #expect(machine.current.token == nil)
    }

    @Test func backspaceBackIntoPreviousTokenReopensAsNewToken() {
        var machine = machine(typing: ":tada")
        let firstID = machine.current.token!.id
        machine.handle(.text(" "))
        #expect(machine.current.token == nil)
        machine.handle(.backspace)
        #expect(machine.current.token?.query == "tada")
        #expect(machine.current.token!.id != firstID)
    }

    @Test func closingColonReportsCompletedShortcode() {
        var machine = machine(typing: "yay :tada")
        let output = machine.handle(.text(":"))
        #expect(output.completedShortcode == "tada")
        #expect(output.token == nil)
    }

    @Test func completionIsReportedOnlyForTheClosingKeystroke() {
        var machine = machine(typing: ":tada:")
        #expect(machine.current.completedShortcode == "tada")
        machine.handle(.text("x"))
        #expect(machine.current.completedShortcode == nil)
    }

    @Test func doubleColonDoesNotComplete() {
        let machine = machine(typing: "::")
        #expect(machine.current.completedShortcode == nil)
        #expect(machine.current.token == nil)
    }

    @Test func colonAfterUnmatchedClosingColonDoesNotRetrigger() {
        // `:foo:bar` — the second colon follows a letter, so no new token.
        #expect(machine(typing: ":foo:bar").current.token == nil)
    }

    @Test func multiCharacterTextCompletesWhenLastCharacterCloses() {
        var machine = TriggerMachine()
        #expect(machine.handle(.text(":tada:")).completedShortcode == "tada")
    }

    @Test func resetForgetsContext() {
        var machine = machine(typing: "http")
        machine.handle(.reset)
        machine.handle(.text(":ok"))
        #expect(machine.current.token?.query == "ok")
    }

    @Test func resetClearsActiveToken() {
        var machine = machine(typing: ":tad")
        machine.handle(.reset)
        #expect(machine.current.token == nil)
        machine.handle(.text("a"))
        #expect(machine.current.token == nil)
    }

    @Test func dismissMarksTokenUntilANewOneStarts() {
        var machine = machine(typing: ":ta")
        machine.handle(.dismiss)
        #expect(machine.current.token?.isDismissed == true)
        machine.handle(.text("da"))
        #expect(machine.current.token?.isDismissed == true)
        #expect(machine.current.token?.query == "tada")
        machine.handle(.text(" :sm"))
        #expect(machine.current.token?.isDismissed == false)
    }

    @Test func dismissedTokenDoesNotCompleteOnClosingColon() {
        var machine = machine(typing: ":tada")
        machine.handle(.dismiss)
        #expect(machine.handle(.text(":")).completedShortcode == nil)
    }

    @Test func dismissWithoutTokenIsNoOp() {
        var machine = machine(typing: "hello")
        machine.handle(.dismiss)
        machine.handle(.text(" :a"))
        #expect(machine.current.token?.isDismissed == false)
    }

    @Test func replacementRewritesHistory() {
        var machine = machine(typing: "hi :tada:")
        machine.handle(.replaced(count: 6, with: "🎉"))
        #expect(machine.current.token == nil)
        // Emoji is a boundary, so a colon right after it triggers.
        machine.handle(.text(":s"))
        #expect(machine.current.token?.query == "s")
    }

    @Test func replacementLongerThanHistoryTreatsStartAsBoundary() {
        var machine = machine(typing: ":ta")
        machine.handle(.replaced(count: 10, with: "x"))
        machine.handle(.backspace)
        machine.handle(.text(":a"))
        #expect(machine.current.token?.query == "a")
    }

    @Test func trimmedHistoryStartIsNotABoundary() {
        var machine = TriggerMachine(maxQueryLength: 4, historyLimit: 8)
        // After trimming, the colon's predecessor ("a") is gone.
        machine.handle(.text("aaaaaaaa"))
        machine.handle(.text(":b"))
        #expect(machine.current.token == nil)
        machine.handle(.text(" :ok"))
        #expect(machine.current.token?.query == "ok")
    }

    @Test func tokenSurvivesHistoryTrimming() {
        var machine = TriggerMachine(maxQueryLength: 4, historyLimit: 8)
        machine.handle(.text("xxxxx :ab"))
        let id = machine.current.token?.id
        machine.handle(.text("c"))
        #expect(machine.current.token?.query == "abc")
        #expect(machine.current.token?.id == id)
    }

    @Test func backspaceOnEmptyHistoryIsSafe() {
        var machine = TriggerMachine()
        machine.handle(.backspace)
        machine.handle(.text(":a"))
        #expect(machine.current.token?.query == "a")
    }
}
