import AppKit
import ApplicationServices
import OpenReactionCore

/// Turns on a Chromium or Electron app's accessibility tree the first time it
/// becomes frontmost, so its text fields become readable.
struct SystemAccessibilityTreeEnabler: AccessibilityTreeEnabling {
    func enableTree(pid: Int32) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium reads AXEnhancedUserInterface, Electron AXManualAccessibility;
        // setting both covers either. Failures are ignored: an app that does
        // not honour them simply stays as it was.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// Reports when keyboard focus may have moved, so capture closes until the
/// focused element is re-checked.
///
/// App activation is reported at once. For focus changes inside the frontmost
/// app an `AXObserver` is registered on a worker queue with a bounded
/// messaging timeout: registration talks to the target process and a busy
/// app must not stall the main thread. Registrations are generation-checked
/// so a slow one for an app that is no longer frontmost is discarded.
///
/// On the same worker pass it enables the frontmost app's accessibility tree
/// once per pid per launch (never for excluded apps), then re-runs tracking,
/// so Chromium and Electron apps expose the focused editable the verified
/// insertion path needs.
@MainActor
final class FocusMonitor {
    /// Called on the main actor whenever focus may have moved.
    var onFocusChange: (() -> Void)?
    /// Called on the main actor when focused-element notifications for the
    /// frontmost app start or stop arriving. Capture stays closed while false.
    var onTrackingChange: ((Bool) -> Void)?
    /// Whether a bundle id is excluded. The tree is never enabled for an
    /// excluded app. Nil is treated as not excluded.
    var isExcluded: ((String?) -> Bool)?
    private(set) var isObservingFrontmost = false

    private let queue = DispatchQueue(label: "com.openappshq.openreaction.focus-observer", qos: .userInitiated)
    private let treeEnabler: any AccessibilityTreeEnabling
    private var activation = AccessibilityActivation()
    private var observer: AXObserver?
    private var generation = 0
    private var activationObserver: NSObjectProtocol?

    init(treeEnabler: any AccessibilityTreeEnabling = SystemAccessibilityTreeEnabler()) {
        self.treeEnabler = treeEnabler
    }

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
        isObservingFrontmost = false
        onTrackingChange?(false)
    }

    private func frontmostChanged() {
        // Close the gate first; the observer for the new app comes later.
        generation += 1
        let current = generation
        isObservingFrontmost = false
        removeObserver()
        onTrackingChange?(false)
        onFocusChange?()

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let excluded = isExcluded?(app.bundleIdentifier) ?? false
        // Decide on the main actor (where the seen-pid set lives); the write
        // itself runs on the worker with a bounded timeout, once per pid.
        let enableTree = activation.shouldEnable(pid: pid, excluded: excluded)
        let refcon = ObserverRegistry.Refcon(Unmanaged.passUnretained(self).toOpaque())
        let treeEnabler = self.treeEnabler
        queue.async { [weak self] in
            if enableTree { treeEnabler.enableTree(pid: pid) }
            let created = ObserverRegistry.register(pid: pid, refcon: refcon)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else {
                        if let created { ObserverRegistry.unregister(created) }
                        return
                    }
                    self.observer = created?.observer
                    self.isObservingFrontmost = created != nil
                    // Becoming tracked asks the gate for a fresh probe.
                    self.onTrackingChange?(created != nil)
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
        // Focused-element changes are required; window changes are a bonus.
        guard AXObserverAddNotification(created, application, kAXFocusedUIElementChangedNotification as CFString, refcon.pointer) == .success else {
            return nil
        }
        _ = AXObserverAddNotification(created, application, kAXFocusedWindowChangedNotification as CFString, refcon.pointer)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        return Registered(observer: created)
    }

    static func unregister(_ registered: Registered) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registered.observer), .defaultMode)
    }
}
