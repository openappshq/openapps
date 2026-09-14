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
/// A replacement is a transaction against the physical event stream: the tap
/// holds keyboard events from `beginHold` until a flush marker posted after
/// the last synthetic event reaches it, then replays them. Typing during the
/// replacement therefore lands after the emoji, never between the deletes.
///
/// Media payloads (GIFs, images) cannot be typed and will need a pasteboard
/// path with explicit clipboard save and restore.
enum TextInserter {
    /// Also used by the tap to replay held events, so posts stay in order.
    static let queue = DispatchQueue(label: "com.openappshq.openreaction.insertion", qos: .userInteractive)
    /// CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
    private static let maxUnitsPerEvent = 20

    /// Deletes `count` characters and types `text`, then posts a flush so the
    /// tap can replay keys typed meanwhile. The caller must have called
    /// `tap.beginHold()` first.
    static func replace(deleting count: Int, with text: String, completion: @escaping @Sendable () -> Void) {
        queue.async {
            defer { completion() }
            guard let source = makeSource() else { return }
            for _ in 0..<max(0, count) {
                postKey(CGKeyCode(kVK_Delete), source: source)
            }
            for chunk in utf16Chunks(text) {
                postUnicode(chunk, source: source)
            }
            postFlush()
        }
    }

    /// Ends a hold without inserting anything.
    static func postFlush() {
        guard let source = makeSource(),
              let marker = CGEvent(keyboardEventSource: source, virtualKey: 0xFF, keyDown: false) else { return }
        marker.flags = []
        marker.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.flush)
        marker.post(tap: .cgSessionEventTap)
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
        source?.userData = KeyboardTap.Tag.passthrough
        return source
    }

    private static func postKey(_ keyCode: CGKeyCode, source: CGEventSource) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.passthrough)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func postUnicode(_ units: [UniChar], source: CGEventSource) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.passthrough)
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
