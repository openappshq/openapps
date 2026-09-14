import Carbon.HIToolbox
import CoreGraphics
import os

/// What a keyboard or mouse event means to OpenReaction.
enum KeyInput: Equatable, Sendable {
    case text(String)
    case backspace
    /// The caret may have moved without typing, or focus may have changed.
    case reset
    case moveUp
    case moveDown
    /// Return, keypad Enter or Tab.
    case confirm
    case escape
    /// A key that neither types nor moves the caret (e.g. a dead-key prefix).
    case ignore

    /// Keys the picker consumes while it is visible.
    var isPickerCommand: Bool {
        switch self {
        case .moveUp, .moveDown, .confirm, .escape: true
        default: false
        }
    }
}

struct TapEvent: Sendable {
    let input: KeyInput
    /// The event was removed from the stream because the picker was visible.
    let swallowed: Bool
    let keyCode: CGKeyCode
}

/// Session-level active `CGEventTap`, run on its own thread.
///
/// The callback does constant-time work only: read the key code, flags and
/// typed characters, decide whether to swallow using a lock-protected flag,
/// and hand the event to the main thread. macOS disables a tap whose callback
/// is slow, so matching, accessibility queries and UI never run here.
final class KeyboardTap: @unchecked Sendable {
    /// Marks events OpenReaction posts itself so the tap lets them through untouched.
    static let syntheticEventTag: Int64 = 0x4F52_4541_4354

    private struct Shared {
        var pickerVisible = false
        /// Picker content frame in Quartz global coordinates.
        var panelFrame = CGRect.null
        var swallowedKeyUps: Set<CGKeyCode> = []
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let handler: @Sendable (TapEvent) -> Void

    // Written on the main thread in start/stop; the port is read on the tap
    // thread only while the tap is installed.
    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?

    init(handler: @escaping @Sendable (TapEvent) -> Void) {
        self.handler = handler
    }

    var isRunning: Bool { machPort != nil }

    func setPicker(visible: Bool, quartzFrame: CGRect?) {
        shared.withLock {
            $0.pickerVisible = visible
            $0.panelFrame = quartzFrame ?? .null
        }
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
        shared.withLock { $0 = Shared() }
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

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            return pass
        }
        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            let swallow = shared.withLock { $0.swallowedKeyUps.remove(keyCode) != nil }
            return swallow ? nil : pass
        }

        let input = Self.classify(keyCode: keyCode, flags: event.flags, text: Self.typedText(event))
        let swallow = input.isPickerCommand && shared.withLock { state in
            guard state.pickerVisible else { return false }
            state.swallowedKeyUps.insert(keyCode)
            return true
        }
        handler(TapEvent(input: input, swallowed: swallow, keyCode: keyCode))
        return swallow ? nil : pass
    }

    private static func typedText(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }

    static func classify(keyCode: CGKeyCode, flags: CGEventFlags, text: String) -> KeyInput {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return .reset
        }
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)
        switch Int(keyCode) {
        case kVK_Delete:
            return option ? .reset : .backspace
        case kVK_UpArrow:
            return shift || option ? .reset : .moveUp
        case kVK_DownArrow:
            return shift || option ? .reset : .moveDown
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return shift || option ? .reset : .confirm
        case kVK_Tab:
            return shift ? .reset : .confirm
        case kVK_Escape:
            return .escape
        case kVK_LeftArrow, kVK_RightArrow, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help:
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
