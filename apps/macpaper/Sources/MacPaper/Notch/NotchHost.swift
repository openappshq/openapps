import AppKit
import MacPaperCore
import SwiftUI

/// Which displays host a panel, from the settings and the screens, and one
/// controller per host. Follows display changes (a notched Mac closed, an
/// external display plugged in), the settings, and the fullscreen watcher.
final class NotchHost {
    private let model: AppModel
    private let preferences: Preferences
    private let onOpenPopover: () -> Void
    private let showSettings: () -> Void
    private let quit: () -> Void
    /// The licensing wiring's header (the trial pill); nil draws nothing.
    var header: (() -> AnyView)?
    /// The menu-bar item's frame in screen coordinates: on a display
    /// without a notch the column opens under it.
    var statusItemFrame: () -> CGRect? = { nil }
    private(set) var controllers: [DisplayID: NotchPanelController] = [:]
    private let fullscreen = FullscreenWatcher()
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, preferences: Preferences, onOpenPopover: @escaping () -> Void, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.onOpenPopover = onOpenPopover
        self.showSettings = showSettings
        self.quit = quit
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        fullscreen.onChange = { [weak self] in self?.applyFullscreen() }
        observeChanges({ [preferences] in
            _ = preferences.notchEnabled; _ = preferences.hostDisplay; _ = preferences.trigger
            _ = preferences.hideInFullscreen; _ = preferences.width; _ = preferences.direction
        }, onChange: { [weak self] in self?.settingsChanged() })
        rebuild()
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Whether any panel can show now (a host exists and the panel is on).
    var hasPanel: Bool { !controllers.isEmpty && preferences.notchEnabled }

    /// The hotkey: toggles the panel on the first host, or opens the
    /// popover when there is none.
    func toggleFromHotkey() {
        guard let controller = primaryController else {
            onOpenPopover()
            return
        }
        controller.handle(.hotkey)
    }

    func closeAll() {
        for controller in controllers.values where controller.isOpen { controller.handle(.clickedOutside) }
    }

    private var primaryController: NotchPanelController? {
        // The display the pointer is on, if it hosts one; else the first host.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), let id = ScreenCatalog.displayID(of: screen), let controller = controllers[id] {
            return controller
        }
        return controllers.sorted { $0.key < $1.key }.first?.value
    }

    /// Re-reads the screens; keeps controllers whose display is still a
    /// host, tears down the others, makes the new ones.
    func rebuild() {
        model.refreshDisplays()
        let hosts = preferences.hostDisplay.hosts(among: model.displays)
        let wanted = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        for (id, controller) in controllers where wanted[id] == nil {
            controller.tearDown()
            controllers[id] = nil
        }
        for (id, display) in wanted {
            guard let screen = ScreenCatalog.screen(for: id) else { continue }
            if let existing = controllers[id] {
                existing.update(screen: screen)
            } else {
                controllers[id] = NotchPanelController(
                    display: display, screen: screen, model: model, preferences: preferences, header: header,
                    statusItemFrame: { [weak self] in self?.statusItemFrame() },
                    onOpenPopover: onOpenPopover, showSettings: showSettings, quit: quit
                )
                controllers[id]?.handle(.settingsChanged(preferences.panelSettings))
            }
        }
        fullscreen.watchedDisplays = Array(controllers.keys)
        applyFullscreen()
    }

    private func settingsChanged() {
        rebuild()
        for controller in controllers.values { controller.settingsChanged() }
    }

    private func applyFullscreen() {
        for (id, controller) in controllers {
            controller.handle(.fullscreenChanged(fullscreen.isFullscreen(display: id)))
        }
    }
}

/// Whether a display's front app is fullscreen, re-read on space changes
/// and app activations from the window list (no permission: bounds only).
final class FullscreenWatcher {
    var onChange: () -> Void = {}
    var watchedDisplays: [DisplayID] = [] {
        didSet { refresh() }
    }
    private var state: [DisplayID: Bool] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        }
    }

    func isFullscreen(display: DisplayID) -> Bool {
        state[display] ?? false
    }

    private func refresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = Self.windows()
        var next: [DisplayID: Bool] = [:]
        for id in watchedDisplays {
            guard let screen = ScreenCatalog.screen(for: id) else { continue }
            next[id] = FullscreenHeuristic.isFullscreen(windows: windows, frontmostPID: frontmost, screenBounds: Self.quartzBounds(of: screen))
        }
        if next != state {
            state = next
            onChange()
        }
    }

    /// On-screen windows with their owner, layer and Quartz bounds.
    private static func windows() -> [FullscreenHeuristic.Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return FullscreenHeuristic.Window(ownerPID: pid, layer: layer, bounds: bounds)
        }
    }

    /// AppKit's bottom-left origin to Quartz's top-left, on the main screen.
    private static func quartzBounds(of screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        return CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
