import Carbon.HIToolbox
import CoreGraphics
import OpenReactionCore
import os

struct TapEvent: Sendable {
    let input: KeyInput
    /// The event was removed from the stream because the picker was visible.
    let swallowed: Bool
    let keyCode: CGKeyCode
}

/// Session-level active `CGEventTap`, run on its own thread.
///
/// The callback does constant-time work only: read the key code and flags,
/// decode typed characters only while text capture is on, decide whether to
/// swallow or hold using lock-protected state, and hand the event to the main
/// thread. macOS disables a tap whose callback is slow, so matching,
/// accessibility queries and UI never run here.
///
/// Three pieces of state shape what the callback does:
/// - `capturesText`: while off (unknown, unavailable or secure focus), typed
///   characters are never decoded, so password keystrokes are not even read.
/// - `pickerVisible`: picker keys are swallowed. A swallowed key press stays
///   owned until it is released, so its repeats and key-up never reach the host.
/// - `holding`: during a text replacement, physical keyboard events are kept
///   aside and replayed afterwards in order, so typing cannot overtake the
///   synthetic deletes and insert.
final class KeyboardTap: @unchecked Sendable {
    /// `eventSourceUserData` values on events OpenReaction posts itself.
    enum Tag {
        /// Deletes, inserted text, replayed keys: pass through untouched.
        static let passthrough: Int64 = 0x4F52_4541_4354
        /// End of a replacement transaction; consumed by the tap, never delivered.
        static let flush: Int64 = 0x4F52_464C_5553
    }

    /// CGEvent is not Sendable; held events are only ever touched under the lock
    /// or on the replay queue.
    private struct HeldEvent: @unchecked Sendable {
        let event: CGEvent
    }

    private struct Shared: Sendable {
        var capturesText = false
        var pickerVisible = false
        /// Picker content frame in Quartz global coordinates.
        var panelFrame = CGRect.null
        /// Keys whose press was swallowed and is still held down.
        var ownedKeys: Set<CGKeyCode> = []
        var holding = false
        /// Physical keyboard events received while holding, in order.
        var held: [HeldEvent] = []
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let handler: @Sendable (TapEvent) -> Void
    /// Serializes replayed events with `TextInserter`'s posts.
    private let replayQueue: DispatchQueue

    // Written on the main thread in start/stop; the port is read on the tap
    // thread only while the tap is installed.
    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?

    init(replayQueue: DispatchQueue, handler: @escaping @Sendable (TapEvent) -> Void) {
        self.replayQueue = replayQueue
        self.handler = handler
    }

    var isRunning: Bool { machPort != nil }

    func setPicker(visible: Bool, quartzFrame: CGRect?) {
        shared.withLock {
            $0.pickerVisible = visible
            $0.panelFrame = quartzFrame ?? .null
        }
    }

    func setCapturesText(_ enabled: Bool) {
        shared.withLock { $0.capturesText = enabled }
    }

    /// Starts keeping physical keyboard events aside. Ends when a `Tag.flush`
    /// event posted after the replacement reaches the tap, which replays the
    /// held events (and repeats until nothing new arrived meanwhile).
    func beginHold() {
        shared.withLock { $0.holding = true }
    }

    /// Replays anything still held, for a transaction whose flush never arrived.
    func endHold() {
        replay(shared.withLock { state in
            state.holding = false
            defer { state.held.removeAll() }
            return state.held
        })
    }

    /// Installs the tap. Returns false when macOS refuses, typically because
    /// Accessibility or Input Monitoring access is missing or not yet applied.
    func start() -> Bool {
        if machPort != nil { return true }
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardTap>.fromOpaque(userInfo).takeUnretainedValue().process(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        machPort = port

        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        nonisolated(unsafe) var threadRunLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "OpenReaction.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = threadRunLoop
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        guard let port = machPort else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        machPort = nil
        runLoop = nil
        // Owned keys are still physically down: post their key-ups so the host
        // does not see a press without a release. Held events are replayed.
        let (owned, held) = shared.withLock { state in
            defer { state = Shared() }
            return (state.ownedKeys, state.held)
        }
        replay(held)
        if !owned.isEmpty {
            replayQueue.async {
                let source = CGEventSource(stateID: .privateState)
                for keyCode in owned {
                    guard let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { continue }
                    up.setIntegerValueField(.eventSourceUserData, value: Tag.passthrough)
                    up.post(tap: .cgSessionEventTap)
                }
            }
        }
    }

    // MARK: - Tap thread

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off; keystrokes may have been missed, so
            // re-enable and forget the typing context.
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            handler(TapEvent(input: .reset, swallowed: false, keyCode: 0))
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let location = event.location
            let onPicker = shared.withLock { $0.pickerVisible && $0.panelFrame.contains(location) }
            if !onPicker {
                handler(TapEvent(input: .reset, swallowed: false, keyCode: 0))
            }
            return pass
        case .keyDown, .keyUp:
            break
        default:
            return pass
        }

        switch event.getIntegerValueField(.eventSourceUserData) {
        case Tag.passthrough:
            return pass
        case Tag.flush:
            didReceiveFlush()
            return nil
        default:
            break
        }

        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        // Ownership and holding are decided together so a held key cannot be
        // released while its press is queued.
        enum Decision { case pass, swallow, hold, deliver(swallowed: Bool) }
        let copy = HeldEvent(event: event.copy() ?? event)
        let decision: Decision = shared.withLock { state in
            if state.holding {
                state.held.append(copy)
                return .hold
            }
            if type == .keyUp {
                return state.ownedKeys.remove(keyCode) != nil ? .swallow : .pass
            }
            if state.ownedKeys.contains(keyCode) {
                // A repeat of a swallowed press: keep it away from the host.
                return state.pickerVisible ? .deliver(swallowed: true) : .swallow
            }
            return .deliver(swallowed: false)
        }
        switch decision {
        case .pass: return pass
        case .swallow, .hold: return nil
        case .deliver(let alreadyOwned):
            let capturesText = shared.withLock { $0.capturesText }
            let text = capturesText ? Self.typedText(event) : ""
            let input = Self.classify(keyCode: keyCode, flags: event.flags, text: text)
            let swallow = alreadyOwned || (input.isPickerCommand && shared.withLock { state in
                guard state.pickerVisible else { return false }
                state.ownedKeys.insert(keyCode)
                return true
            })
            handler(TapEvent(input: input, swallowed: swallow, keyCode: keyCode))
            return swallow ? nil : pass
        }
    }

    /// The replacement's events have all passed. Replay what was held; if
    /// more arrived in the meantime, `TextInserter` posts another flush.
    private func didReceiveFlush() {
        let held = shared.withLock { state -> [HeldEvent] in
            guard state.holding else { return [] }
            if state.held.isEmpty {
                state.holding = false
                return []
            }
            defer { state.held.removeAll() }
            return state.held
        }
        guard !held.isEmpty else { return }
        replay(held)
        replayQueue.async { TextInserter.postFlush() }
    }

    private func replay(_ events: [HeldEvent]) {
        guard !events.isEmpty else { return }
        replayQueue.async {
            for held in events {
                held.event.setIntegerValueField(.eventSourceUserData, value: Tag.passthrough)
                held.event.post(tap: .cgSessionEventTap)
            }
        }
    }

    private static func typedText(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }

    /// Only unmodified keys mean anything to OpenReaction. Command, Control
    /// and Option chords are shortcuts for the host app and reset typing.
    static func classify(keyCode: CGKeyCode, flags: CGEventFlags, text: String) -> KeyInput {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return .reset
        }
        let shift = flags.contains(.maskShift)
        switch Int(keyCode) {
        case kVK_Delete:
            return .backspace
        case kVK_UpArrow, kVK_LeftArrow:
            return shift ? .reset : .movePrevious
        case kVK_DownArrow, kVK_RightArrow:
            return shift ? .reset : .moveNext
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return shift ? .reset : .confirm
        case kVK_Tab:
            return shift ? .reset : .confirm
        case kVK_Escape:
            return shift ? .reset : .escape
        case kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help:
            return .reset
        default:
            guard !text.isEmpty else { return .ignore }
            let isControlOrFunctionKey = text.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
            }
            return isControlOrFunctionKey ? .reset : .text(text)
        }
    }
}
