import AppKit
import MacPaperCore
import SwiftUI

/// One display's panel: the column itself, a borderless non-activating
/// `NSPanel` hung under the menu-bar item and placed by
/// `PanelGeometry.panelFrame` inside the display's visible frame. Every
/// open or close goes through the core's `PanelStateMachine`; this class
/// only owns the window and the monitors the machine's effects ask for.
///
/// macOS caveats, and what is done about them:
/// - A click outside is seen by a global mouse-down monitor, which needs no
///   permission for mouse buttons; keyboard events would, so Escape is a
///   local monitor and works while the panel is key (after typing in it).
/// - Fullscreen is not announced either: `FullscreenWatcher` reads the
///   window list on space and app changes (bounds need no permission).
/// - The panel is `nonactivatingPanel`, so opening it never takes focus
///   from the app in front; a text field in it makes it key on click.
/// - The column's height follows its content (`min(content, cap)`): the
///   view reports its natural height as it lays out, and the window
///   follows with its top edge fixed.
final class PanelController {
    let display: DisplayInfo
    private(set) var screen: NSScreen
    private let model: AppModel
    private let preferences: Preferences
    private let showSettings: () -> Void
    private let quit: () -> Void
    /// The menu-bar item's frame in screen coordinates, when it has one:
    /// the column hangs under it.
    private let statusItemFrame: () -> CGRect?
    /// The window the menu-bar item lives in: a click there is the item's
    /// own toggle (delivered on mouse-up), never a click outside.
    private let statusItemWindow: () -> NSWindow?
    /// The licensing wiring's header (the trial pill), read at every
    /// layout; nil draws nothing.
    private let header: () -> AnyView?

    private(set) var machine: PanelStateMachine
    private let panel: NSPanel
    private let hosting: NSHostingView<PanelContent>
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var escapeMonitor: Any?
    /// What the content last asked for; nil before the first layout.
    private var naturalHeight: CGFloat?

    var isOpen: Bool { machine.isOpen }

    init(display: DisplayInfo, screen: NSScreen, model: AppModel, preferences: Preferences, header: @escaping () -> AnyView? = { nil }, statusItemFrame: @escaping () -> CGRect? = { nil }, statusItemWindow: @escaping () -> NSWindow? = { nil }, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.display = display
        self.header = header
        self.screen = screen
        self.model = model
        self.preferences = preferences
        self.statusItemFrame = statusItemFrame
        self.statusItemWindow = statusItemWindow
        self.showSettings = showSettings
        self.quit = quit
        machine = PanelStateMachine(hideInFullscreen: preferences.hideInFullscreen)

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        // The column is dark in both appearances (PanelTheme).
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = PanelContent(model: model, width: PanelMetrics.width(for: preferences.width), header: header(), showSettings: showSettings, quit: quit)
        hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
    }

    deinit {
        MainActor.assumeIsolated {
            removeMonitors()
            panel.orderOut(nil)
        }
    }

    // MARK: - Events

    func handle(_ event: PanelEvent) {
        guard let effect = machine.handle(event) else { return }
        switch effect {
        case .open: show()
        case .close: hide()
        }
    }

    /// The screen was re-read (resolution, arrangement): an open column
    /// is placed again.
    func update(screen: NSScreen) {
        self.screen = screen
        if machine.isOpen { layoutPanel(animated: false) }
    }

    func settingsChanged() {
        handle(.settingsChanged(hideInFullscreen: preferences.hideInFullscreen))
        if machine.isOpen { layoutPanel(animated: false) }
    }

    func tearDown() {
        handle(.hostLost)
    }

    // MARK: - Window

    /// The menu-bar item's frame when it sits on this screen.
    private var item: CGRect? {
        statusItemFrame().flatMap { screen.frame.intersects($0) ? $0 : nil }
    }

    /// The column's height for the content it has, up to the display's cap.
    private var columnHeight: CGFloat {
        let cap = PanelLayout.heightCap(visibleHeight: screen.visibleFrame.height)
        return PanelLayout.columnHeight(contentHeight: naturalHeight ?? cap, visibleHeight: screen.visibleFrame.height)
    }

    /// The content laid out at another natural height (a section switched,
    /// a status line appeared): the window follows, its top edge fixed.
    /// Reported from inside a layout pass, so the frame change waits for
    /// the next turn of the run loop.
    private func contentHeightChanged(_ natural: CGFloat) {
        guard abs((naturalHeight ?? -1) - natural) > 0.5 else { return }
        naturalHeight = natural
        guard machine.isOpen, abs(columnHeight - panel.frame.height) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.machine.isOpen, abs(self.columnHeight - self.panel.frame.height) > 0.5 else { return }
                self.layoutPanel(animated: true)
            }
        }
    }

    private func layoutPanel(animated: Bool) {
        let height = columnHeight
        let width = PanelMetrics.width(for: preferences.width)
        hosting.rootView = PanelContent(
            model: model, width: width, height: height, header: header(),
            showSettings: showSettings, quit: quit, dismiss: { [weak self] in self?.handle(.escape) },
            onNaturalHeight: { [weak self] in self?.contentHeightChanged($0) }
        )
        let frame = PanelGeometry.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, item: item, width: width, contentHeight: height)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Brand.Motion.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func show() {
        model.targetDisplay = display.id
        model.clearStatus()
        // The content's natural height, measured before the window shows,
        // so the column opens at its final size; the view's own report
        // refines it afterwards.
        let width = PanelMetrics.width(for: preferences.width)
        naturalHeight = PanelMetrics.naturalHeight(of: PanelContent(model: model, width: width, header: header(), showSettings: {}, quit: {}))
        layoutPanel(animated: false)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let final = panel.frame
        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.setFrame(final.offsetBy(dx: 0, dy: 10), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Brand.Motion.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
            }
        }
        installMonitors()
    }

    private func hide() {
        removeMonitors()
        if panel.isKeyWindow { panel.resignKey() }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Brand.Motion.fast
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.machine.isOpen else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.clickedOutside) }
        }
        // A click in one of the app's other windows (Settings) is outside
        // too; not one on the menu-bar item, whose mouse-up toggles.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.clickIsOutside(window: event.window, own: [self.panel, self.statusItemWindow()]) { self.handle(.clickedOutside) }
            }
            return event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, event.window === self.panel else { return false }
                self.handle(.escape)
                return true
            }
            return handled ? nil : event
        }
    }

    /// Whether a mouse-down in `window` is a click outside the panel: any
    /// window but the panel's own and the menu-bar item's (whose click is
    /// the item's toggle, on mouse-up).
    static func clickIsOutside(window: AnyObject?, own: [AnyObject?]) -> Bool {
        !own.contains { $0 != nil && $0 === window }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
        escapeMonitor = nil
    }
}

/// The column in its shape: the opaque dark ground, rounded all round
/// under the menu-bar item, the rim the design system specifies.
struct PanelContent: View {
    let model: AppModel
    let width: CGFloat
    /// The column's height; nil sizes to the content (the harness, and the
    /// measurement the window takes before it shows).
    var height: CGFloat? = nil
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    var dismiss: () -> Void = {}
    /// The content's natural height as it lays out (`WallpaperPanelView`).
    var onNaturalHeight: ((CGFloat) -> Void)? = nil

    var body: some View {
        let shape = PanelShape()
        WallpaperPanelView(model: model, width: width, height: height, header: header, showSettings: showSettings, quit: quit, dismiss: dismiss, onNaturalHeight: onNaturalHeight)
            .background(PanelBackdrop(shape: shape))
            .clipShape(shape)
            .overlay(PanelRim(shape: shape))
    }
}

/// The ground behind the column: `PanelTheme.ground`, opaque in every
/// case (Reduce Transparency changes nothing, there is nothing to
/// reduce); under Increase Contrast the rim brightens.
struct PanelBackdrop: View {
    let shape: PanelShape

    var body: some View {
        shape.fill(Brand.Panel.ground)
    }
}

/// The 1-point rim: neutral/700 on the ground, brighter under Increase
/// Contrast.
struct PanelRim: View {
    let shape: PanelShape
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        shape.strokeBorder(contrast == .increased ? Brand.Panel.textPrimary.opacity(0.6) : Brand.Panel.rim, lineWidth: 1)
    }
}

/// The column's outline: rounded all round at the panel radius.
struct PanelShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(Brand.Radius.panel, r.width / 2, r.height / 2)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> PanelShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}
