import AppKit
import ApplicationServices

/// Reports when keyboard focus may have moved, so capture closes until the
/// focused element is re-checked.
///
/// App activation is reported at once. For focus changes inside the frontmost
/// app an `AXObserver` is registered on a worker queue with a bounded
/// messaging timeout: registration talks to the target process and a busy
/// app must not stall the main thread. Registrations are generation-checked
/// so a slow one for an app that is no longer frontmost is discarded.
@MainActor
final class FocusMonitor {
    /// Called on the main actor. `reliable` is false while no observer is
    /// registered for the frontmost app.
    var onFocusChange: (() -> Void)?
    private(set) var isObservingFrontmost = false

    private let queue = DispatchQueue(label: "com.openappshq.openreaction.focus-observer", qos: .userInitiated)
    private var observer: AXObserver?
    private var generation = 0
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        frontmostChanged()
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        generation += 1
        removeObserver()
    }

    private func frontmostChanged() {
        // Close the gate first; the observer for the new app comes later.
        generation += 1
        let current = generation
        isObservingFrontmost = false
        removeObserver()
        onFocusChange?()

        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let refcon = ObserverRegistry.Refcon(Unmanaged.passUnretained(self).toOpaque())
        queue.async { [weak self] in
            let created = ObserverRegistry.register(pid: pid, refcon: refcon)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else {
                        if let created { ObserverRegistry.unregister(created) }
                        return
                    }
                    self.observer = created?.observer
                    self.isObservingFrontmost = created != nil
                    // Focus may have changed while registration was in flight.
                    self.onFocusChange?()
                }
            }
        }
    }

    private func removeObserver() {
        if let observer { ObserverRegistry.unregister(ObserverRegistry.Registered(observer: observer)) }
        observer = nil
    }
}

/// Talks to the target process; runs on the monitor's worker queue.
private enum ObserverRegistry {
    struct Refcon: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        init(_ pointer: UnsafeMutableRawPointer) { self.pointer = pointer }
    }

    struct Registered: @unchecked Sendable {
        let observer: AXObserver
    }

    /// Returns a registered observer whose run-loop source is attached to the
    /// main run loop, or nil if the app did not cooperate.
    static func register(pid: pid_t, refcon: Refcon) -> Registered? {
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onFocusChange?() }
        }, &created)
        guard status == .success, let created else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var registered = 0
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            if AXObserverAddNotification(created, application, notification as CFString, refcon.pointer) == .success {
                registered += 1
            }
        }
        guard registered > 0 else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        return Registered(observer: created)
    }

    static func unregister(_ registered: Registered) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registered.observer), .defaultMode)
    }
}
