import AppKit
@testable import MacPaper
import MacPaperCore
import Testing

/// The global shortcut (`HotkeyCenter`, Carbon's `RegisterEventHotKey`): no
/// window, no status item — only the registration itself.
@MainActor
struct HotkeyCenterTests {
    @Test("The default registers; unregistering clears it; an invalid hotkey registers nothing and reports why")
    func register() {
        let center = HotkeyCenter()
        center.register(.default)
        #expect(center.registered == .default)
        #expect(center.problem == nil)
        center.unregister()
        #expect(center.registered == nil)

        let invalid = Hotkey(keyCode: 0, modifiers: .shift)
        center.register(invalid)
        #expect(center.problem != nil)
        #expect(center.registered == nil)
    }

    @Test("A hotkey's modifiers translate to the menu's modifier mask")
    func modifierMask() {
        #expect(StatusItemController.modifierMask(Hotkey.default.modifiers) == [.option, .command])
        #expect(StatusItemController.modifierMask([.command, .shift, .option, .control]) == [.command, .shift, .option, .control])
        #expect(StatusItemController.modifierMask([]) == [])
    }
}
