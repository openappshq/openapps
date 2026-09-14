import AppKit
import ApplicationServices

/// Reports when keyboard focus may have moved, so the focused element can be
/// re-checked before any text is captured.
///
/// Watches the frontmost app through an `AXObserver` for focused-element
/// changes (covers Tab, clicks and programmatic focus inside that app), and
/// app activation for switches between apps. Apps without Accessibility
/// support post no notifications; their focus is re-checked on activation,
/// on every reset key, and at each colon.
@MainActor
final class FocusMonitor {
    var onFocusChange: (() -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
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
        removeObserver()
    }

    private func frontmostChanged() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != observedPID {
            removeObserver()
            if pid != 0 { installObserver(pid: pid) }
        }
        onFocusChange?()
    }

    private func installObserver(pid: pid_t) {
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onFocusChange?() }
        }, &created)
        guard status == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, application, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }
}
