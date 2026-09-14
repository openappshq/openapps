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

    let environment = Environment()
    let anchor = CGRect(x: 10, y: 20, width: 0, height: 18)

    private func makeCoordinator() -> TypingCoordinator {
        let environment = environment
        return TypingCoordinator(
            isSecureInputEnabled: { environment.secureInput },
            isFrontmostAppExcluded: { environment.excludedApp }
        )
    }

    private func type(_ text: String, into coordinator: inout TypingCoordinator) -> [TypingCoordinator.Effect] {
        text.flatMap { coordinator.handle(.text(String($0))) }
    }

    private func hasInsert(_ effects: [TypingCoordinator.Effect]) -> Bool {
        effects.contains {
            if case .insertShortcode = $0 { return true }
            if case .commitSelection = $0 { return true }
            return false
        }
    }

    // MARK: Blocker 1 — insertion waits for a completed, editable focus check

    @Test func closingColonBeforeFocusIsKnownInsertsNothing() {
        var coordinator = makeCoordinator()
        let effects = type(":tada:", into: &coordinator)
        #expect(effects.contains(.requestFocus(tokenID: 1)))
        #expect(!hasInsert(effects))
    }

    @Test func closingColonAfterEditableFocusInserts() {
        var coordinator = makeCoordinator()
        _ = type(":tada", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, .editable(anchor: anchor))
        let effects = coordinator.handle(.text(":"))
        #expect(effects.contains(.insertShortcode("tada", replacing: 6)))
    }

    @Test func unavailableFocusInsertsNothingAndShowsNoPicker() {
        var coordinator = makeCoordinator()
        _ = type(":tad", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, .unavailable) == [.dismissPicker])
        #expect(coordinator.handle(.text("a")) == [.dismissPicker])
        #expect(!hasInsert(coordinator.handle(.text(":"))))
    }

    @Test func secureFocusInsertsNothingOnClosingColon() {
        var coordinator = makeCoordinator()
        _ = type(":tada", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, .secure)
        #expect(!hasInsert(coordinator.handle(.text(":"))))
    }

    @Test func lateFocusAnswerForAnOldTokenIsIgnored() {
        var coordinator = makeCoordinator()
        _ = type(":ta ", into: &coordinator)
        _ = type(":sm", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, .editable(anchor: anchor)).isEmpty)
        #expect(coordinator.token?.query == "sm")
        let effects = coordinator.focusResolved(tokenID: 2, .editable(anchor: anchor))
        #expect(effects == [.presentPicker(query: "sm", anchor: anchor)])
    }

    @Test func excludedAppNeverAsksForFocusOrInserts() {
        environment.excludedApp = true
        var coordinator = makeCoordinator()
        let effects = type(":tada:", into: &coordinator)
        #expect(!effects.contains(.requestFocus(tokenID: 1)))
        #expect(!hasInsert(effects))
    }

    @Test func pickerAppearsOnlyAfterFocusAndTwoCharacters() {
        var coordinator = makeCoordinator()
        _ = type(":t", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, .editable(anchor: anchor)) == [.dismissPicker])
        #expect(coordinator.handle(.text("a")) == [.presentPicker(query: "ta", anchor: anchor)])
    }

    // MARK: Blocker 2 — secure contexts buffer nothing

    @Test func secureFieldResetsTheMachineAndStopsBuffering() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        #expect(coordinator.focusResolved(tokenID: 1, .secure) == [.dismissPicker])
        #expect(coordinator.token == nil)
        // Still in the password field: keystrokes are dropped, not buffered.
        let effects = type("da: :tada:", into: &coordinator)
        #expect(effects.isEmpty)
        #expect(coordinator.token == nil)
        #expect(coordinator.handle(.backspace).isEmpty)
    }

    @Test func focusChangeAfterSecureFieldResumesNormally() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, .secure)
        _ = coordinator.handle(.reset)
        let effects = type(":sm", into: &coordinator)
        #expect(effects.contains(.requestFocus(tokenID: 2)))
        #expect(coordinator.token?.query == "sm")
    }

    @Test func secureInputDropsEveryKeystroke() {
        environment.secureInput = true
        var coordinator = makeCoordinator()
        let effects = type(":tada:", into: &coordinator)
        #expect(!effects.contains { if case .requestFocus = $0 { return true } else { return false } })
        #expect(!hasInsert(effects))
        #expect(coordinator.token == nil)
    }

    @Test func secureInputTurningOnMidTokenDropsTheToken() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, .editable(anchor: anchor))
        coordinator.isPickerVisible = true
        environment.secureInput = true
        #expect(coordinator.handle(.text("d")) == [.dismissPicker])
        #expect(coordinator.token == nil)
        // A swallowed picker key during secure input is given back, never acted on.
        #expect(coordinator.handle(.confirm, swallowed: true) == [.repost, .dismissPicker])
        environment.secureInput = false
        _ = coordinator.handle(.reset)
        #expect(type(":ok", into: &coordinator).contains(.requestFocus(tokenID: 2)))
    }

    // MARK: Blocker 3 — picker commands act only on keys the tap swallowed

    private func makeVisiblePicker() -> TypingCoordinator {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, .editable(anchor: anchor))
        coordinator.isPickerVisible = true
        return coordinator
    }

    @Test func swallowedCommandsDriveTheVisiblePicker() {
        var coordinator = makeVisiblePicker()
        #expect(coordinator.handle(.moveNext, swallowed: true) == [.moveSelection(by: 1)])
        #expect(coordinator.handle(.movePrevious, swallowed: true) == [.moveSelection(by: -1)])
        #expect(coordinator.handle(.confirm, swallowed: true) == [.commitSelection(replacing: 3)])
    }

    @Test func unswallowedCommandsNeverChangeState() {
        for input in [KeyInput.moveNext, .movePrevious, .confirm, .escape] {
            var coordinator = makeVisiblePicker()
            let effects = coordinator.handle(input, swallowed: false)
            // The host app received the key, so the caret moved or text changed.
            #expect(effects == [.dismissPicker])
            #expect(!hasInsert(effects))
            #expect(!effects.contains { if case .moveSelection = $0 { return true } else { return false } })
            #expect(coordinator.token == nil)
        }
    }

    @Test func swallowedCommandWithHiddenPickerIsRepostedNotActedOn() {
        var coordinator = makeVisiblePicker()
        coordinator.isPickerVisible = false
        #expect(coordinator.handle(.confirm, swallowed: true) == [.repost, .dismissPicker])
        var second = makeVisiblePicker()
        second.isPickerVisible = false
        #expect(second.handle(.moveNext, swallowed: true) == [.repost, .dismissPicker])
    }

    @Test func swallowedEscapeDismissesOnlyTheCurrentToken() {
        var coordinator = makeVisiblePicker()
        #expect(coordinator.handle(.escape, swallowed: true) == [.dismissPicker])
        #expect(coordinator.token?.isDismissed == true)
        coordinator.isPickerVisible = false
        #expect(!hasInsert(coordinator.handle(.text(":"))))
    }

    @Test func confirmWithoutEditableFocusIsRepostedEvenIfPickerLooksVisible() {
        var coordinator = makeCoordinator()
        _ = type(":ta", into: &coordinator)
        coordinator.isPickerVisible = true
        #expect(coordinator.handle(.confirm, swallowed: true) == [.repost, .dismissPicker])
    }

    // MARK: Insertion bookkeeping

    @Test func didInsertRewritesHistorySoTheNextColonTriggers() {
        var coordinator = makeCoordinator()
        _ = type("hi :tada", into: &coordinator)
        _ = coordinator.focusResolved(tokenID: 1, .editable(anchor: anchor))
        _ = coordinator.handle(.text(":"))
        coordinator.didInsert("🎉", replacing: 6)
        #expect(coordinator.token == nil)
        #expect(type(":s", into: &coordinator).contains(.requestFocus(tokenID: 2)))
    }
}
