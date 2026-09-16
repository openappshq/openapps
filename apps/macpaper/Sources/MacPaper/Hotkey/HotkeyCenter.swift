import AppKit
import Carbon.HIToolbox
import MacPaperCore
import Observation

/// The global hotkey through Carbon's `RegisterEventHotKey`: system-wide,
/// no Accessibility or Input Monitoring needed, and the only key the app
/// ever sees is its own shortcut. The handler runs on the main run loop.
@Observable
final class HotkeyCenter {
    /// Why the current hotkey could not be registered (taken by another
    /// app, or invalid); nil while it works or there is none.
    private(set) var problem: String?
    private(set) var registered: Hotkey?
    @ObservationIgnored var onPressed: () -> Void = {}
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private static let signature: OSType = 0x6D_50_50_52 // "mPPR"

    init() {}

    deinit {
        MainActor.assumeIsolated {
            unregister()
            removeHandler()
        }
    }

    /// Removes the Carbon handler (with the hotkey): at quit, or when the
    /// center is dropped.
    func removeHandler() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// Registers the hotkey (replacing the previous one); nil removes it.
    func register(_ hotkey: Hotkey?) {
        unregister()
        guard let hotkey else {
            problem = nil
            return
        }
        guard hotkey.isValid else {
            problem = hotkey.problem
            return
        }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.modifiers.carbonFlags, id, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registered = hotkey
            problem = nil
        } else {
            problem = status == OSStatus(eventHotKeyExistsErr)
                ? "\(hotkey.displayString) is taken by another app."
                : "macOS refused \(hotkey.displayString) (error \(status))."
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registered = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.onPressed() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
    }
}
