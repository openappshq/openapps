import AppKit
import MacPaperCore
import SwiftUI

/// One `PanelController` per display the panel has opened on: the display
/// the menu-bar item is on, made on demand. Follows display changes (an
/// external display plugged in or removed), the settings, and the
/// fullscreen watcher, and routes the menu-bar item and the shortcut to
/// the item's display.
final class PanelHost {
    private let model: AppModel
    private let preferences: Preferences
    private let showSettings: () -> Void
    private let quit: () -> Void
    /// The licensing wiring's header (the trial pill); nil draws nothing.
    var header: (() -> AnyView)?
    /// The menu-bar item's frame in screen coordinates: the column opens
    /// under it.
    var statusItemFrame: () -> CGRect? = { nil }
    /// The menu-bar item's window: a click in it is the item's own toggle,
    /// never a click outside the panel.
    var statusItemWindow: () -> NSWindow? = { nil }
    private(set) var controllers: [DisplayID: PanelController] = [:]
    private let fullscreen = FullscreenWatcher()
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, preferences: Preferences, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.showSettings = showSettings
        self.quit = quit
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        fullscreen.onChange = { [weak self] in self?.applyFullscreen() }
        observeChanges({ [preferences] in
            _ = preferences.hideInFullscreen; _ = preferences.width
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

    /// The menu-bar item's click and the shortcut alike: closes the open
    /// panel, else opens one under the item on its display.
    func toggle() {
        if let open = controllers.values.first(where: \.isOpen) {
            open.handle(.toggle)
            return
        }
        statusItemController()?.handle(.toggle)
    }

    /// Opens the panel under the menu-bar item (a recipe file opened from
    /// the Finder); nothing if one is open already.
    func show() {
        guard !isOpen else { return }
        toggle()
    }

    /// The controller for the menu-bar item's display, made on demand.
    private func statusItemController() -> PanelController? {
        guard let screen = statusItemFrame().flatMap({ frame in NSScreen.screens.first { $0.frame.intersects(frame) } }) ?? NSScreen.main,
              let id = ScreenCatalog.displayID(of: screen) else { return nil }
        if let existing = controllers[id] { return existing }
        guard let display = ScreenCatalog.info(for: screen) else { return nil }
        let controller = PanelController(
            display: display, screen: screen, model: model, preferences: preferences,
            header: { [weak self] in self?.header?() },
            statusItemFrame: { [weak self] in self?.statusItemFrame() },
            statusItemWindow: { [weak self] in self?.statusItemWindow() },
            showSettings: showSettings, quit: quit
        )
        controllers[id] = controller
        // Watching the display reads its fullscreen state at once.
        fullscreen.watchedDisplays = Array(controllers.keys)
        return controller
    }

    /// Re-reads the screens; keeps every controller whose display is still
    /// connected, tears down the others.
    func rebuild() {
        model.refreshDisplays()
        for (id, controller) in controllers {
            guard let screen = ScreenCatalog.screen(for: id) else {
                controller.tearDown()
                controllers[id] = nil
                continue
            }
            controller.update(screen: screen)
        }
        fullscreen.watchedDisplays = Array(controllers.keys)
        applyFullscreen()
    }

    private func settingsChanged() {
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
