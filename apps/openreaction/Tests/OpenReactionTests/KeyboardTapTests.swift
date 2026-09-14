import Carbon.HIToolbox
import CoreGraphics
import OpenReactionCore
import Testing
@testable import OpenReaction

/// Feeds constructed (never posted) CGEvents through the real tap callback,
/// runner and gate, so flag conversion and Unicode decoding are covered with
/// the actual CoreGraphics types, not hand-built `KeyEvent`s.
@Suite("Keyboard tap", .serialized)
@MainActor
struct KeyboardTapTests {
    final class Recorder: @unchecked Sendable {
        var effects: [GateRunner.MainEffect] = []
    }

    struct Fixture {
        let runner: GateRunner
        let tap: KeyboardTap
        let recorder = Recorder()

        init() {
            let recorder = self.recorder
            runner = GateRunner(gate: InputGate()) { effects in recorder.effects += effects }
            // The test host may itself have Secure Event Input on; the tap
            // is told it is off so the decoding path is exercised.
            tap = KeyboardTap(runner: runner, isSecureInputEnabled: { false })
            runner.focusTracking(active: true)
            let probe = lastProbe!
            runner.probeResult(generation: probe.generation, tokenID: nil, .editable(anchor: .zero, target: FocusTarget(pid: 1, element: 1)))
        }

        /// A US-layout key press with the given flags; the event carries the
        /// characters macOS would produce for that key and flags.
        func key(_ keyCode: CGKeyCode, _ characters: String, flags: CGEventFlags = [], down: Bool = true) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
            event.flags = flags
            var units = Array(characters.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            return event
        }

        /// Returns true if the tap passed the event to the host.
        @discardableResult
        func send(_ event: CGEvent, type: CGEventType? = nil) -> Bool {
            tap.process(type: type ?? event.type, event: event) != nil
        }

        var lastProbe: (generation: Int, tokenID: Int?)? {
            recorder.effects.reversed().lazy.compactMap {
                if case .requestProbe(let g, let t) = $0 { return (g, t) } else { return nil }
            }.first
        }
    }

    @Test func shiftColonIsDecodedAndStartsAHold() {
        let fixture = Fixture()
        let colon = fixture.key(41, ":", flags: .maskShift)
        #expect(!fixture.send(colon)) // held until the probe answers
        #expect(fixture.lastProbe?.tokenID != nil)
    }

    @Test(arguments: [
        CGEventFlags([.maskShift, CGEventFlags(rawValue: 0x2)]),      // right Shift device bit
        CGEventFlags([.maskShift, .maskSecondaryFn]),
        CGEventFlags([.maskShift, .maskNumericPad]),
        CGEventFlags([.maskShift, .maskAlphaShift]),
    ])
    func shiftWithHarmlessFlagsStillDecodes(flags: CGEventFlags) {
        let fixture = Fixture()
        #expect(!fixture.send(fixture.key(41, ":", flags: flags)))
        #expect(fixture.lastProbe?.tokenID != nil)
    }

    @Test(arguments: [CGEventFlags([.maskShift, .maskCommand]), [.maskShift, .maskAlternate], [.maskShift, .maskControl]])
    func chordsPassAndCloseCapture(flags: CGEventFlags) {
        let fixture = Fixture()
        #expect(fixture.send(fixture.key(41, ":", flags: flags)))
        #expect(fixture.lastProbe?.tokenID == nil)
        #expect(!fixture.runner.capturesText)
    }

    @Test func fullShortcodeThroughTheTapProducesTheToken() {
        let fixture = Fixture()
        let keys: [(CGKeyCode, String, CGEventFlags)] = [(41, ":", .maskShift), (17, "t", []), (0, "a", []), (2, "d", []), (0, "a", [])]
        for (code, text, flags) in keys {
            fixture.send(fixture.key(code, text, flags: flags))
            fixture.send(fixture.key(code, "", flags: flags, down: false))
        }
        let probe = fixture.lastProbe!
        fixture.runner.probeResult(generation: probe.generation, tokenID: probe.tokenID, .editable(anchor: .zero, target: FocusTarget(pid: 1, element: 1)))
        // The held keys were decoded from the real events and replayed.
        let presented = fixture.recorder.effects.contains {
            if case .presentPicker(let query, _) = $0 { return query == "tada" } else { return false }
        }
        // Presenting waits for the replay flush; simulate it.
        let flush = fixture.key(0xFF, "", down: false)
        flush.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.flush, id: 1))
        #expect(!fixture.send(flush))
        let presentedAfterFlush = fixture.recorder.effects.contains {
            if case .presentPicker(let query, _) = $0 { return query == "tada" } else { return false }
        }
        #expect(presented || presentedAfterFlush)
    }

    @Test func passthroughTaggedEventsAreNeverInterpreted() {
        let fixture = Fixture()
        let colon = fixture.key(41, ":", flags: .maskShift)
        colon.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.passthrough))
        #expect(fixture.send(colon))
        #expect(fixture.lastProbe?.tokenID == nil)
    }

    @Test func secureInputDropsDecodingThroughTheTap() {
        let recorder = Recorder()
        let runner = GateRunner(gate: InputGate()) { effects in recorder.effects += effects }
        let tap = KeyboardTap(runner: runner, isSecureInputEnabled: { true })
        runner.focusTracking(active: true)
        runner.probeResult(generation: 0, tokenID: nil, .editable(anchor: .zero, target: FocusTarget(pid: 1, element: 1)))
        let colon = CGEvent(keyboardEventSource: nil, virtualKey: 41, keyDown: true)!
        colon.flags = .maskShift
        var units = Array(":".utf16)
        colon.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        #expect(tap.process(type: .keyDown, event: colon) != nil)
        #expect(!recorder.effects.contains { if case .requestProbe(_, let t) = $0 { return t != nil } else { return false } })
    }

    @Test func mouseDownClosesCaptureThroughTheTap() {
        let fixture = Fixture()
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 5, y: 5), mouseButton: .left)!
        #expect(fixture.send(click))
        #expect(!fixture.runner.capturesText)
    }
}
