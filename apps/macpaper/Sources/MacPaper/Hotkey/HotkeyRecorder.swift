import AppKit
import MacPaperCore
import SwiftUI

/// A field that records a shortcut: click, press the keys, done. Escape
/// cancels, Delete clears. The field takes key events only while it is
/// first responder, so nothing is monitored globally.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    var problem: String?
    @State private var recording = false
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            if previewRendering {
                // `ImageRenderer` draws no NSView: the field's look, static.
                Text(hotkey?.displayString ?? "None")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 140, height: 28)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            } else {
                RecorderField(hotkey: $hotkey, recording: $recording)
                    .frame(width: 140, height: 28)
                    .accessibilityLabel("Hotkey")
                    .accessibilityValue(hotkey?.displayString ?? "none")
                    .accessibilityHint("Activate, then press the keys")
            }
            if hotkey != nil, !recording {
                Button("Clear") { hotkey = nil }
                    .buttonStyle(LinkButtonStyle())
            }
            if let problem {
                Text(problem)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.dangerSolid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RecorderField: NSViewRepresentable {
    @Binding var hotkey: Hotkey?
    @Binding var recording: Bool

    func makeNSView(context: Context) -> RecorderControl {
        let control = RecorderControl()
        control.onChange = { hotkey = $0 }
        control.onRecordingChange = { recording = $0 }
        return control
    }

    func updateNSView(_ control: RecorderControl, context: Context) {
        control.hotkey = hotkey
    }
}

final class RecorderControl: NSControl {
    var hotkey: Hotkey? {
        didSet { needsDisplay = true }
    }
    var onChange: (Hotkey?) -> Void = { _ in }
    var onRecordingChange: (Bool) -> Void = { _ in }
    private var recording = false {
        didSet {
            onRecordingChange(recording)
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType { get { .exterior } set {} }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: // Escape
            recording = false
            window?.makeFirstResponder(nil)
        case 51, 117: // Delete, forward delete
            onChange(nil)
            recording = false
            window?.makeFirstResponder(nil)
        default:
            var modifiers: Hotkey.Modifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            let candidate = Hotkey(keyCode: event.keyCode, modifiers: modifiers)
            guard candidate.isValid else {
                // Reserved or modifier-less: refused here, before Carbon.
                NSSound.beep()
                return
            }
            onChange(candidate)
            recording = false
            window?.makeFirstResponder(nil)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? "Press keys…" : (hotkey?.displayString ?? "None")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: recording || hotkey == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
