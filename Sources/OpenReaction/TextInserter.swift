import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts the keyboard events that carry out a replacement, in order.
///
/// Why synthetic Unicode key events rather than the pasteboard: pasting
/// overwrites the user's clipboard, and restoring it races the target app's
/// asynchronous read of the pasteboard; clipboard managers record every
/// insertion; Command-V is rebound or disabled in some apps and fields. A
/// keyboard event carrying a Unicode string goes through the app's normal
/// typing path, so undo, autocorrect and field formatters behave as if the
/// user typed the emoji.
///
/// Everything here is posted from one serial queue, enqueued in the order the
/// `InputGate` decided, so deletes, text, flush markers and replayed physical
/// keys reach the session event stream in that order.
///
/// Media payloads (GIFs, images) cannot be typed and will need a pasteboard
/// path with explicit clipboard save and restore.
enum TextInserter {
    static let queue = DispatchQueue(label: "com.openappshq.openreaction.insertion", qos: .userInteractive)
    /// CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
    private static let maxUnitsPerEvent = 20

    /// Deletes `deleteCount` characters, types `text`, then posts the flush for
    /// the transaction. If events cannot be created the flush is still posted,
    /// so the gate learns the phase is over instead of waiting for the watchdog.
    static func postReplacement(transaction: Int, deleteCount: Int, text: String) {
        queue.async {
            if let source = makeSource() {
                for _ in 0..<max(0, deleteCount) {
                    postKey(CGKeyCode(kVK_Delete), source: source)
                }
                for chunk in utf16Chunks(text) {
                    postUnicode(chunk, source: source)
                }
            }
            postFlushNow(transaction: transaction)
        }
    }

    static func postFlush(transaction: Int) {
        queue.async { postFlushNow(transaction: transaction) }
    }

    /// Re-posts physical events the tap held, tagged so it passes them through.
    static func replay(_ events: [CGEvent]) {
        let boxed = events.map(EventBox.init)
        queue.async {
            for box in boxed {
                box.event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.passthrough))
                box.event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Sends a synthetic press of a key the tap swallowed but could not use.
    static func repost(keyCode: UInt16) {
        queue.async {
            guard let source = makeSource() else { return }
            postKey(CGKeyCode(keyCode), source: source)
        }
    }

    private struct EventBox: @unchecked Sendable {
        let event: CGEvent
    }

    private static func postFlushNow(transaction: Int) {
        guard let source = makeSource(),
              let marker = CGEvent(keyboardEventSource: source, virtualKey: 0xFF, keyDown: false) else { return }
        marker.flags = []
        marker.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.flush, id: transaction))
        marker.post(tap: .cgSessionEventTap)
    }

    private static func makeSource() -> CGEventSource? {
        // A private state source does not inherit modifier keys the user is
        // still holding, so a held Shift cannot turn Delete into something else.
        let source = CGEventSource(stateID: .privateState)
        source?.userData = KeyboardTap.Tag.userData(KeyboardTap.Tag.passthrough)
        return source
    }

    private static func postKey(_ keyCode: CGKeyCode, source: CGEventSource) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.passthrough))
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func postUnicode(_ units: [UniChar], source: CGEventSource) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.passthrough))
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
