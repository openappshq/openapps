import Carbon.HIToolbox
import CoreGraphics
import OpenReactionCore
import os

/// Session-level active `CGEventTap`, run on its own thread.
///
/// The tap is deliberately thin: it turns each event into a `KeyEvent`, asks
/// the `GateRunner` (and through it the pure `InputGate`) what to do, and
/// returns that decision. Typed characters are decoded only when the gate
/// asks for them. macOS disables a tap whose callback is slow, so nothing
/// else happens here.
final class KeyboardTap: @unchecked Sendable {
    /// High 32 bits of `eventSourceUserData` on events OpenReaction posts.
    enum Tag {
        /// Deletes, inserted text, replayed keys: pass through untouched.
        static let passthrough: Int64 = 0x4F52_4541
        /// End of a transaction phase; the low 32 bits carry the transaction id.
        static let flush: Int64 = 0x4F52_464C

        static func userData(_ tag: Int64, id: Int = 0) -> Int64 {
            (tag << 32) | Int64(id & 0xFFFF_FFFF)
        }

        static func split(_ userData: Int64) -> (tag: Int64, id: Int) {
            (userData >> 32, Int(userData & 0xFFFF_FFFF))
        }
    }

    private let runner: GateRunner
    /// `IsSecureEventInputEnabled` in the app; tests supply a controlled value.
    private let isSecureInputEnabled: @Sendable () -> Bool

    // Written on the main thread in start/stop; the port is read on the tap
    // thread only while the tap is installed.
    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?

    init(runner: GateRunner, isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
        self.runner = runner
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    var isRunning: Bool { machPort != nil }

    /// Events the window server aims at this process (our own windows).
    static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    /// Installs the tap. Returns false when macOS refuses, typically because
    /// Accessibility or Input Monitoring access is missing or not yet applied.
    func start() -> Bool {
        if machPort != nil { return true }
        let mask: CGEventMask = [
            CGEventType.keyDown, .keyUp,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ].reduce(0) { $0 | (1 << $1.rawValue) }
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
        runner.tapStopped()
    }

    // MARK: - Tap thread

    /// Internal so tests can drive it with constructed, unposted events.
    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let (tag, id) = Tag.split(event.getIntegerValueField(.eventSourceUserData))
        let mouseKind: MouseEventKind?
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off; keystrokes may have been missed and
            // any flush marker may be lost. Re-enable and start over.
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            runner.tapInterrupted()
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: mouseKind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: mouseKind = .up
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: mouseKind = .drag
        case .keyDown, .keyUp: mouseKind = nil
        default:
            return pass
        }
        if tag == Tag.passthrough {
            return pass
        }
        let targetsOwnApp = event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(Self.ownProcessID)
        if let mouseKind {
            return runner.mouse(mouseKind, at: event.location, event: event, targetsOwnApp: targetsOwnApp) == .pass ? pass : nil
        }
        if tag == Tag.flush {
            runner.flushAck(transaction: id)
            return nil
        }

        let flags = event.flags
        var modifiers: KeyModifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }

        let decision = runner.key(
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            isDown: type == .keyDown,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            modifiers: modifiers,
            secureInput: isSecureInputEnabled(),
            event: event,
            targetsOwnApp: targetsOwnApp,
            text: { Self.typedText(event) }
        )
        switch decision {
        case .pass: return pass
        case .swallow, .hold: return nil
        }
    }

    static func typedText(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}
