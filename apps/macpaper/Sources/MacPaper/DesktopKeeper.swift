import AppKit
import MacPaperCore

/// Pin so it stays: whenever macOS may have put something else on a
/// display — launch, wake, unlock, the active Space changing, displays
/// changing — the keeper asks each recorded display what it shows and
/// re-applies macPaper's own file where it differs (`PinPolicy`). Displays
/// applied "this Space only" are left alone. Never re-renders: the file
/// that was applied is handed over again. Off when the setting is off.
final class DesktopKeeper {
    private let model: AppModel
    private let preferences: Preferences
    private let desktop: any DesktopApplier
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    /// What the last check did, for Copy Diagnostics.
    private(set) var lastReport = "not run yet"

    init(model: AppModel, preferences: Preferences, desktop: any DesktopApplier) {
        self.model = model
        self.preferences = preferences
        self.desktop = desktop
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(reason: name.rawValue) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(reason: "displays changed") }
        })
        // The lock screen going away: a distributed notification, no permission.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(reason: "unlocked") }
        })
        check(reason: "launch")
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                NotificationCenter.default.removeObserver(observer)
                DistributedNotificationCenter.default().removeObserver(observer)
            }
        }
    }

    /// Coalesces bursts (a Space change fires with a display change) and
    /// gives macOS a moment to settle before asking what it shows.
    func check(reason: String) {
        guard preferences.keepApplied else {
            lastReport = "off"
            return
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.reapplyIfNeeded(reason: reason)
        }
    }

    private func reapplyIfNeeded(reason: String) {
        let state = model.appliedState
        let connected = Set(model.displays.map(\.id))
        let displays = PinPolicy.displaysToReapply(
            recorded: state.recordedFiles, current: { [desktop] in desktop.currentImageURL(for: $0) },
            excluded: state.perSpaceDisplayIDs, connected: connected
        )
        guard !displays.isEmpty else {
            lastReport = "\(reason): nothing to do"
            return
        }
        var done: [DisplayID] = []
        var failed: [String] = []
        for display in displays {
            guard let file = state.file(for: display) else { continue }
            do {
                try model.applier.reapply(file, to: display)
                done.append(display)
            } catch {
                failed.append("\(display): \(error.localizedDescription)")
            }
        }
        lastReport = "\(reason): re-applied \(done.map(String.init).joined(separator: ", "))" + (failed.isEmpty ? "" : "; failed \(failed.joined(separator: "; "))")
    }
}

/// The Mac's light/dark appearance changing: `AppleInterfaceThemeChangedNotification`
/// on the distributed center, no permission. Drives the fallback swap and
/// the preview's side.
final class ThemeWatcher {
    private var observer: NSObjectProtocol?

    init(onChange: @escaping @MainActor () -> Void) {
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        }
    }
}

/// `macpaper://s/<code>`: a shared document becomes the draft. The app's
/// single `kAEGetURL` handler (`AppDelegate.registerURLHandler`, and the
/// licensing wiring's `openDeepLink` once merged) calls `routeSharedLink`
/// first and handles other hosts (`activate`) itself; nothing here
/// registers a handler of its own.
extension AppDelegate {
    /// True when the link was a share link and was consumed.
    @discardableResult
    func routeSharedLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ShareCode.scheme, url.host?.lowercased() == ShareCode.host else { return false }
        model.open(sharedLink: url)
        return true
    }

    /// The one Apple-event handler for `macpaper://` links.
    func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        openDeepLink(url)
    }

    /// Dispatches by host: `s` is a share link; other hosts (`activate`,
    /// the licensing wiring's) are ignored here until that wiring lands.
    func openDeepLink(_ url: URL) {
        if routeSharedLink(url) { return }
    }
}
