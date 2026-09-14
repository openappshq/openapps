import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Replaces the typed shortcode in the focused app by posting keyboard events.
///
/// Why synthetic Unicode key events rather than the pasteboard: pasting
/// overwrites the user's clipboard, and restoring it races the target app's
/// asynchronous read of the pasteboard; clipboard managers record every
/// insertion; Command-V is rebound or disabled in some apps and fields. A
/// keyboard event carrying a Unicode string goes through the app's normal
/// typing path, so undo, autocorrect and field formatters behave as if the
/// user typed the emoji.
///
/// Media payloads (GIFs, images) cannot be typed and will need a pasteboard
/// path with explicit clipboard save and restore.
enum TextInserter {
    private static let queue = DispatchQueue(label: "com.openappshq.openreaction.insertion", qos: .userInteractive)
    /// CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
    private static let maxUnitsPerEvent = 20

    static func replace(deleting count: Int, with text: String) {
        queue.async {
            guard let source = makeSource() else { return }
            for _ in 0..<max(0, count) {
                postKey(CGKeyCode(kVK_Delete), source: source)
            }
            for chunk in utf16Chunks(text) {
                postUnicode(chunk, source: source)
            }
        }
    }

    /// Re-sends a key that the tap swallowed but the picker could no longer use.
    static func repost(keyCode: CGKeyCode) {
        queue.async {
            guard let source = makeSource() else { return }
            postKey(keyCode, source: source)
        }
    }

    private static func makeSource() -> CGEventSource? {
        // A private state source does not inherit modifier keys the user is
        // still holding, so a held Shift cannot turn Delete into something else.
        let source = CGEventSource(stateID: .privateState)
        source?.userData = KeyboardTap.syntheticEventTag
        return source
    }

    private static func postKey(_ keyCode: CGKeyCode, source: CGEventSource) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.syntheticEventTag)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func postUnicode(_ units: [UniChar], source: CGEventSource) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.syntheticEventTag)
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Splits text into event-sized chunks without cutting a grapheme cluster.
    private static func utf16Chunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty && current.count + units.count > maxUnitsPerEvent {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
