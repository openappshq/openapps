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
/// What the gate runner posts through. The app posts real events; tests
/// substitute a recorder so nothing reaches the session.
protocol EventPoster: Sendable {
    /// Deletes, types, then flushes — only if `commit` agrees when the work
    /// runs. `onFailure` is called instead if the flush could not be posted.
    func postReplacement(transaction: Int, deleteCount: Int, text: String, commit: @escaping @Sendable () -> Bool, onFailure: @escaping @Sendable () -> Void)
    /// Posts the flush marker; `onFailure` if it could not be posted.
    func postFlush(transaction: Int, onFailure: @escaping @Sendable () -> Void)
    /// Re-posts held physical events in order; `completion` runs once they
    /// have been posted (on the posting queue, after them). With a `guard`,
    /// `shouldPost` is asked on the queue right before posting: if it says
    /// no, nothing is posted and `dropped` gets the count instead.
    func replay(_ events: [CGEvent], guard: ReplayGuard?, completion: (@Sendable () -> Void)?)
    func repost(keyCode: UInt16)
}

/// Decides at execution time whether a delayed replay may still be posted.
struct ReplayGuard: Sendable {
    let shouldPost: @Sendable () -> Bool
    let dropped: @Sendable (Int) -> Void
}

/// The app's poster: `TextInserter`.
struct LiveEventPoster: EventPoster {
    func postReplacement(transaction: Int, deleteCount: Int, text: String, commit: @escaping @Sendable () -> Bool, onFailure: @escaping @Sendable () -> Void) {
        TextInserter.postReplacement(transaction: transaction, deleteCount: deleteCount, text: text, commit: commit, onFailure: onFailure)
    }

    func postFlush(transaction: Int, onFailure: @escaping @Sendable () -> Void) {
        TextInserter.postFlush(transaction: transaction, onFailure: onFailure)
    }

    func replay(_ events: [CGEvent], guard: ReplayGuard?, completion: (@Sendable () -> Void)?) {
        TextInserter.replay(events, guard: `guard`, completion: completion)
    }

    func repost(keyCode: UInt16) {
        TextInserter.repost(keyCode: keyCode)
    }
}

enum TextInserter {
    static let queue = DispatchQueue(label: "com.openappshq.openreaction.insertion", qos: .userInteractive)
    /// CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
    private static let maxUnitsPerEvent = 20

    /// Deletes `deleteCount` characters, types `text`, then posts the flush for
    /// the transaction — but only if `commit` agrees at that moment. If the
    /// commit is refused nothing is posted (the gate has already arranged its
    /// own flush). If events cannot be created the flush is still posted, so
    /// the gate learns the phase is over instead of waiting for the watchdog;
    /// if the flush itself cannot be posted, `onFailure` says so.
    static func postReplacement(transaction: Int, deleteCount: Int, text: String, commit: @escaping @Sendable () -> Bool, onFailure: @escaping @Sendable () -> Void) {
        queue.async {
            guard commit() else { return }
            if let source = makeSource() {
                for _ in 0..<max(0, deleteCount) {
                    postKey(CGKeyCode(kVK_Delete), source: source)
                }
                for chunk in utf16Chunks(text) {
                    postUnicode(chunk, source: source)
                }
            }
            if !postFlushNow(transaction: transaction) { onFailure() }
        }
    }

    static func postFlush(transaction: Int, onFailure: @escaping @Sendable () -> Void) {
        queue.async {
            if !postFlushNow(transaction: transaction) { onFailure() }
        }
    }

    /// Re-posts physical events the tap held, tagged so it passes them
    /// through; `completion` runs on the queue right after them. A guard is
    /// consulted right before posting, so a focus change after the replay
    /// was queued still stops it.
    static func replay(_ events: [CGEvent], guard: ReplayGuard? = nil, completion: (@Sendable () -> Void)? = nil) {
        let boxed = events.map(EventBox.init)
        queue.async {
            if let `guard`, !boxed.isEmpty, !`guard`.shouldPost() {
                `guard`.dropped(boxed.count)
            } else {
                for box in boxed {
                    box.event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.passthrough))
                    box.event.post(tap: .cgSessionEventTap)
                }
            }
            completion?()
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

    /// False when the marker could not be created: no acknowledgement will
    /// ever come for this flush.
    private static func postFlushNow(transaction: Int) -> Bool {
        guard let source = makeSource(),
              let marker = CGEvent(keyboardEventSource: source, virtualKey: 0xFF, keyDown: false) else { return false }
        marker.flags = []
        marker.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.Tag.userData(KeyboardTap.Tag.flush, id: transaction))
        marker.post(tap: .cgSessionEventTap)
        return true
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
