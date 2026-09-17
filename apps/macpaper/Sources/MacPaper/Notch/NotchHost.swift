import AppKit
import MacPaperCore
import SwiftUI

/// One `NotchPanelController` per display the panel can open on: the
/// displays that host the notch panel (from the settings and the screens),
/// and any display the menu-bar item has been clicked on. Follows display
/// changes (a notched Mac closed, an external display plugged in), the
/// settings, and the fullscreen watcher, and routes the hotkey and the
/// menu-bar item to the right controller.
final class NotchHost {
    private let model: AppModel
    private let preferences: Preferences
    private let showSettings: () -> Void
    private let quit: () -> Void
    /// The licensing wiring's header (the trial pill); nil draws nothing.
    var header: (() -> AnyView)?
    /// The menu-bar item's frame in screen coordinates: the column opens
    /// under it on a click on the item, and for the hotkey where the
    /// notch panel cannot show.
    var statusItemFrame: () -> CGRect? = { nil }
    /// The menu-bar item's window: a click in it is the item's own toggle,
    /// never a click outside the panel.
    var statusItemWindow: () -> NSWindow? = { nil }
    /// The first-run glow's flags; nil never shows the glow (the harness).
    private let hintFlags: (any FlagStore)?
    private(set) var controllers: [DisplayID: NotchPanelController] = [:]
    private let fullscreen = FullscreenWatcher()
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, preferences: Preferences, hintFlags: (any FlagStore)? = UserDefaults.standard, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.hintFlags = hintFlags
        self.showSettings = showSettings
        self.quit = quit
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        fullscreen.onChange = { [weak self] in self?.applyFullscreen() }
        observeChanges({ [preferences] in
            _ = preferences.notchEnabled; _ = preferences.hostDisplay; _ = preferences.trigger
            _ = preferences.hideInFullscreen; _ = preferences.width; _ = preferences.direction
            _ = preferences.hoverDelay
        }, onChange: { [weak self] in self?.settingsChanged() })
        rebuild()
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Whether a panel is open on any display.
    var isOpen: Bool { controllers.values.contains(where: \.isOpen) }

    /// The hotkey toggles: closes the open panel, else opens one — from
    /// the notch on the display the pointer is on when it hosts the notch
    /// panel and may show it, else the first such host, else under the
    /// menu-bar item on its display.
    func toggleFromHotkey() {
        if let open = controllers.values.first(where: \.isOpen) {
            open.handle(.hotkey)
            return
        }
        guard let controller = primaryController ?? statusItemController() else { return }
        controller.handle(.hotkey)
    }

    /// The menu-bar item toggles the panel under itself, on its display.
    func toggleFromStatusItem() {
        guard let controller = statusItemController() else { return }
        closeAll(except: controller)
        controller.handle(.statusItemClicked)
    }

    /// Opens the panel under the menu-bar item (a recipe file opened from
    /// the Finder); nothing if one is open already.
    func showFromStatusItem() {
        guard !isOpen else { return }
        toggleFromStatusItem()
    }

    func closeAll(except kept: NotchPanelController? = nil) {
        for controller in controllers.values where controller.isOpen && controller !== kept { controller.handle(.clickedOutside) }
    }

    /// The notch host the hotkey drops from: the pointer's display when it
    /// hosts the notch panel and may show it now (on, not hidden by
    /// fullscreen), else the first such host; nil sends the hotkey under
    /// the menu-bar item.
    private var primaryController: NotchPanelController? {
        let hosts = controllers.filter { $0.value.hostsNotch && $0.value.machine.canShow }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), let id = ScreenCatalog.displayID(of: screen), let controller = hosts[id] {
            return controller
        }
        return hosts.sorted { $0.key < $1.key }.first?.value
    }

    /// The controller for the menu-bar item's display, made on demand: a
    /// display that does not host the notch panel still opens the column
    /// under the item.
    private func statusItemController() -> NotchPanelController? {
        guard let frame = statusItemFrame(), let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main,
              let id = ScreenCatalog.displayID(of: screen) else { return nil }
        if let existing = controllers[id] { return existing }
        guard let display = ScreenCatalog.info(for: screen) else { return nil }
        let controller = makeController(display: display, screen: screen, hostsNotch: false)
        controllers[id] = controller
        fullscreen.watchedDisplays = Array(controllers.keys)
        return controller
    }

    private func makeController(display: DisplayInfo, screen: NSScreen, hostsNotch: Bool) -> NotchPanelController {
        let controller = NotchPanelController(
            display: display, screen: screen, model: model, preferences: preferences, hostsNotch: hostsNotch,
            header: { [weak self] in self?.header?() },
            statusItemFrame: { [weak self] in self?.statusItemFrame() },
            statusItemWindow: { [weak self] in self?.statusItemWindow() },
            hintFlags: hintFlags,
            showSettings: showSettings, quit: quit
        )
        controller.handle(.settingsChanged(preferences.panelSettings))
        return controller
    }

    /// Re-reads the screens; keeps every controller whose display is still
    /// connected (hosting the notch panel or not, as the settings say now),
    /// tears down the others, makes the missing hosts.
    func rebuild() {
        model.refreshDisplays()
        let hosts = preferences.hostDisplay.hosts(among: model.displays)
        let wanted = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        for (id, controller) in controllers {
            guard let screen = ScreenCatalog.screen(for: id) else {
                controller.tearDown()
                controllers[id] = nil
                continue
            }
            controller.hostsNotch = wanted[id] != nil
            controller.update(screen: screen)
        }
        for (id, display) in wanted where controllers[id] == nil {
            guard let screen = ScreenCatalog.screen(for: id) else { continue }
            controllers[id] = makeController(display: display, screen: screen, hostsNotch: true)
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
