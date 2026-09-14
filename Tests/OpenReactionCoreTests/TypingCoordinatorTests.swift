import CoreGraphics
import OpenReactionCore
import Testing

@Suite("Typing coordinator")
struct TypingCoordinatorTests {
    /// Test doubles for the two synchronous environment checks.
    final class Environment: @unchecked Sendable {
        var secureInput = false
        var excludedApp = false
    }

    typealias Effect = TypingCoordinator.Effect

    let environment = Environment()
    let anchor = CGRect(x: 10, y: 20, width: 0, height: 18)
    let field = FocusTarget(pid: 42, element: 7)
    let otherField = FocusTarget(pid: 42, element: 8)

    private var editable: FocusResult { .editable(anchor: anchor, target: field) }

    /// A coordinator whose focus is already known to be an editable field.
    private func makeCoordinator(focused: Bool = true) -> TypingCoordinator {
        let environment = environment
        var coordinator = TypingCoordinator(
            isSecureInputEnabled: { environment.secureInput },
            isFrontmostAppExcluded: { environment.excludedApp }
        )
        if focused { _ = coordinator.focusChanged(editable) }
        return coordinator
    }

    private func type(_ text: String, into coordinator: inout TypingCoordinator) -> [Effect] {
        text.flatMap { coordinator.handle(.text(String($0))) }
    }

    private func inserts(_ effects: [Effect]) -> [Insertion] {
        effects.compactMap { if case .insert(let insertion) = $0 { return insertion } else { return nil } }
    }

    private func requestsFocus(_ effects: [Effect]) -> Bool {
        effects.contains { if case .requestFocus = $0 { return true } else { return false } }
    }

    // MARK: Text capture follows the focused element

    @Test func nothingIsCapturedUntilFocusIsKnownEditable() {
        var coordinator = makeCoordinator(focused: false)
        #expect(!coordinator.capturesText)
        #expect(type(":tada:", into: &coordinator).isEmpty)
        #expect(coordinator.token == nil)
    }

    @Test(arguments: [FocusResult.secure, .unavailable])
    func secureOrUnavailableFocusCapturesNothing(result: FocusResult) {
        var coordinator = makeCoordinator(focused: false)
        #expect(coordinator.focusChanged(result) == [.dismissPicker])
        #expect(!coordinator.capturesText)
        #expect(type(":tada:", into: &coordinator).isEmpty)
        #expect(coordinator.handle(.backspace).isEmpty)
        #expect(coordinator.token == nil)
    }

    @Test func focusMovingToASecureFieldMidTokenDropsTheToken() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        #expect(coordinator.token?.query == "ta")
        #expect(coordinator.focusChanged(.secure) == [.dismissPicker])
        #expect(coordinator.token == nil)
        #expect(type("da:", into: &coordinator).isEmpty)
    }

    @Test func focusMovingToAnotherFieldForgetsTyping() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        _ = coordinator.focusChanged(.editable(anchor: anchor, target: otherField))
        #expect(coordinator.token == nil)
        #expect(coordinator.capturesText)
    }

    @Test func repeatedSameFocusKeepsTyping() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        #expect(coordinator.focusChanged(editable).isEmpty)
        #expect(coordinator.token?.query == "ta")
    }

    @Test func focusRegainedAfterSecureFieldResumesNormally() {
        var coordinator = makeCoordinator()
        _ = coordinator.focusChanged(.secure)
        _ = coordinator.focusChanged(editable)
        #expect(requestsFocus(type(":sm", into: &coordinator)))
        #expect(coordinator.token?.query == "sm")
    }

    // MARK: Insertion waits for a completed, editable focus check

    @Test func closingColonBeforeTheTokenProbeAnswersInsertsNothing() {
        var coordinator = makeCoordinator()
        let effects = type(":tada:", into: &coordinator)
        #expect(effects.contains(.requestFocus(tokenID: 1)))
        #expect(inserts(effects).isEmpty)
    }

    @Test func closingColonAfterEditableProbeInserts() {
        var coordinator = makeCoordinator()
        _ = type(":TaDa", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, editable)
        let effects = coordinator.handle(.text(":"))
        #expect(effects == [.dismissPicker, .insert(Insertion(source: .shortcode("tada"), typed: ":TaDa:", target: field))])
    }

    @Test(arguments: [FocusResult.secure, .unavailable])
    func probeAnsweringNotEditableForgetsTheToken(result: FocusResult) {
        var coordinator = makeCoordinator()
        _ = type(":tada", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, result) == [.dismissPicker])
        #expect(coordinator.token == nil)
        #expect(!coordinator.capturesText)
        #expect(inserts(coordinator.handle(.text(":"))).isEmpty)
    }

    @Test func lateProbeAnswerForAnOldTokenIsIgnored() {
        var coordinator = makeCoordinator()
        _ = type(":ta ", into: &coordinator)
        _ = type(":sm", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, editable).isEmpty)
        #expect(coordinator.token?.query == "sm")
        #expect(coordinator.focusResolved(tokenID: 2, editable) == [.presentPicker(query: "sm", anchor: anchor)])
    }

    @Test func excludedAppNeverProbesOrInserts() {
        environment.excludedApp = true
        var coordinator = makeCoordinator()
        let effects = type(":tada:", into: &coordinator)
        #expect(!requestsFocus(effects))
        #expect(inserts(effects).isEmpty)
    }

    @Test func pickerAppearsOnlyAfterProbeAndTwoCharacters() {
        var coordinator = makeCoordinator()
        _ = type(":t", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, editable) == [.dismissPicker])
        #expect(coordinator.handle(.text("a")) == [.presentPicker(query: "ta", anchor: anchor)])
    }

    // MARK: Secure input

    @Test func secureInputDropsEveryKeystroke() {
        environment.secureInput = true
        var coordinator = makeCoordinator()
        let effects = type(":tada:", into: &coordinator)
        #expect(!requestsFocus(effects))
        #expect(inserts(effects).isEmpty)
        #expect(coordinator.token == nil)
    }

    @Test func secureInputTurningOnMidTokenDropsTheToken() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, editable)
        coordinator.isPickerVisible = true
        environment.secureInput = true
        #expect(coordinator.handle(.text("d")) == [.dismissPicker])
        #expect(coordinator.token == nil)
        // A swallowed picker key during secure input is given back, never acted on.
        #expect(coordinator.handle(.confirm, swallowed: true) == [.repost, .dismissPicker])
    }

    // MARK: Picker commands act only on keys the tap swallowed

    private func makeVisiblePicker() -> TypingCoordinator {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, editable)
        coordinator.isPickerVisible = true
        return coordinator
    }

    @Test func swallowedCommandsDriveTheVisiblePicker() {
        var coordinator = makeVisiblePicker()
        #expect(coordinator.handle(.moveNext, swallowed: true) == [.moveSelection(by: 1)])
        #expect(coordinator.handle(.movePrevious, swallowed: true) == [.moveSelection(by: -1)])
        #expect(coordinator.handle(.confirm, swallowed: true) == [
            .dismissPicker, .insert(Insertion(source: .selection, typed: ":ta", target: field)),
        ])
    }

    @Test func unswallowedCommandsNeverChangeState() {
        for input in [KeyInput.moveNext, .movePrevious, .confirm, .escape] {
            var coordinator = makeVisiblePicker()
            // The host app received the key, so the caret moved or text changed.
            #expect(coordinator.handle(input, swallowed: false) == [.dismissPicker])
            #expect(coordinator.token == nil)
        }
    }

    @Test func swallowedCommandWithHiddenPickerIsRepostedNotActedOn() {
        for input in [KeyInput.moveNext, .confirm, .escape] {
            var coordinator = makeVisiblePicker()
            coordinator.isPickerVisible = false
            #expect(coordinator.handle(input, swallowed: true) == [.repost, .dismissPicker])
        }
    }

    @Test func swallowedEscapeDismissesOnlyTheCurrentToken() {
        var coordinator = makeVisiblePicker()
        #expect(coordinator.handle(.escape, swallowed: true) == [.dismissPicker])
        #expect(coordinator.token?.isDismissed == true)
        coordinator.isPickerVisible = false
        #expect(inserts(coordinator.handle(.text(":"))).isEmpty)
    }

    @Test func confirmWithoutAProbeAnswerIsRepostedEvenIfPickerLooksVisible() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        coordinator.isPickerVisible = true
        #expect(coordinator.handle(.confirm, swallowed: true) == [.repost, .dismissPicker])
    }

    // MARK: Insertion lifecycle

    @Test func keysDuringAPendingInsertionAreNotInterpreted() {
        var coordinator = makeVisiblePicker()
        let insertion = inserts(coordinator.handle(.confirm, swallowed: true)).first!
        #expect(coordinator.handle(.text("x")).isEmpty)
        #expect(coordinator.handle(.confirm, swallowed: true) == [.repost])
        #expect(coordinator.insertionFinished(insertion, inserted: "🎉") == [.dismissPicker])
        #expect(coordinator.token == nil)
        // History now ends with the emoji, a boundary, so a new colon triggers.
        #expect(requestsFocus(type(":s", into: &coordinator)))
    }

    @Test func failedInsertionForgetsTyping() {
        var coordinator = makeVisiblePicker()
        let insertion = inserts(coordinator.handle(.confirm, swallowed: true)).first!
        #expect(coordinator.insertionFinished(insertion, inserted: nil) == [.dismissPicker])
        #expect(coordinator.token == nil)
        #expect(coordinator.capturesText)
    }

    @Test func staleInsertionOutcomeIsIgnored() {
        var coordinator = makeVisiblePicker()
        let insertion = inserts(coordinator.handle(.confirm, swallowed: true)).first!
        _ = coordinator.insertionFinished(insertion, inserted: "🎉")
        #expect(coordinator.insertionFinished(insertion, inserted: nil).isEmpty)
    }

    @Test func insertionCarriesTheTypedTextAndTarget() {
        var coordinator = makeCoordinator()
        _ = type("hi :Tada", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, editable)
        let insertion = inserts(coordinator.handle(.text(":"))).first
        #expect(insertion?.typed == ":Tada:")
        #expect(insertion?.replacingCount == 6)
        #expect(insertion?.target == field)
    }
}
