import AppKit
import MacPaperCore
import SwiftUI

/// One display's notch panel: a transparent hover window over the notch
/// (or the hot edge of a display without one) that reports the pointer and
/// clicks, and the panel itself, a borderless non-activating `NSPanel` under
/// the menu bar, centered on the notch. Every open or close goes through the
/// core's `PanelStateMachine`; this class only owns the windows, the
/// timers and the monitors the machine's effects ask for.
///
/// macOS caveats, and what is done about them:
/// - Nothing reports "the pointer is over the notch": the hover window sits
///   exactly on the notch rect (`NSScreen.auxiliaryTop*Area`) at a level
///   above the menu bar and takes a tracking area. The notch is dead space,
///   so covering it costs nothing; on a display without a notch the zone is
///   a 2-point strip so no menu-bar item is covered.
/// - A click outside is seen by a global mouse-down monitor, which needs no
///   permission for mouse buttons; keyboard events would, so Escape is a
///   local monitor and works while the panel is key (after typing in it).
/// - Fullscreen is not announced either: `FullscreenWatcher` reads the
///   window list on space and app changes (bounds need no permission).
/// - The panel is `nonactivatingPanel`, so opening it never takes focus
///   from the app in front; a text field in it makes it key on click.
final class NotchPanelController {
    let display: DisplayInfo
    private(set) var screen: NSScreen
    private let model: AppModel
    private let preferences: Preferences
    private let onOpenPopover: () -> Void
    private let showSettings: () -> Void
    private let quit: () -> Void

    private(set) var machine: PanelStateMachine
    private let hoverWindow: NSPanel
    private let panel: NSPanel
    private let hosting: NSHostingView<PanelContent>
    private var timers: [PanelTimer: Timer] = [:]
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var escapeMonitor: Any?

    var isOpen: Bool { machine.isOpen }

    /// The licensing wiring's header (the trial pill); nil draws nothing.
    let header: (() -> AnyView)?

    init(display: DisplayInfo, screen: NSScreen, model: AppModel, preferences: Preferences, header: (() -> AnyView)? = nil, onOpenPopover: @escaping () -> Void, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.display = display
        self.header = header
        self.screen = screen
        self.model = model
        self.preferences = preferences
        self.onOpenPopover = onOpenPopover
        self.showSettings = showSettings
        self.quit = quit
        machine = PanelStateMachine(settings: preferences.panelSettings)

        hoverWindow = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hoverWindow.isOpaque = false
        hoverWindow.backgroundColor = .clear
        hoverWindow.hasShadow = false
        hoverWindow.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hoverWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hoverWindow.isReleasedWhenClosed = false
        hoverWindow.hidesOnDeactivate = false
        hoverWindow.isFloatingPanel = true
        hoverWindow.becomesKeyOnlyIfNeeded = true
        hoverWindow.acceptsMouseMovedEvents = true

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
        let content = PanelContent(model: model, width: preferences.width.points, header: header?(), showSettings: showSettings, quit: quit)
        hosting = NSHostingView(rootView: content)
        let container = PanelContainerView(hosting: hosting)
        container.onContentHeightChange = { [weak self] in self?.contentGrew() }
        panel.contentView = container

        let zone = HoverZoneView(frame: .zero)
        hoverWindow.contentView = zone
        zone.onEnter = { [weak self] in self?.handle(.pointerEnteredNotch) }
        zone.onExit = { [weak self] in self?.handle(.pointerLeftNotch) }
        zone.onClick = { [weak self] in self?.handle(.notchClicked) }
        container.onEnter = { [weak self] in self?.handle(.pointerEnteredPanel) }
        container.onExit = { [weak self] in self?.handle(.pointerLeftPanel) }

        layoutHoverZone()
        hoverWindow.orderFrontRegardless()
    }

    deinit {
        MainActor.assumeIsolated {
            for timer in timers.values { timer.invalidate() }
            removeMonitors()
            hoverWindow.orderOut(nil)
            panel.orderOut(nil)
        }
    }

    // MARK: - Events

    func handle(_ event: PanelEvent) {
        for effect in machine.handle(event) { perform(effect) }
    }

    /// The screen was re-read (resolution, arrangement): the zone follows.
    func update(screen: NSScreen) {
        self.screen = screen
        layoutHoverZone()
        if machine.isOpen { layoutPanel() }
    }

    func settingsChanged() {
        handle(.settingsChanged(preferences.panelSettings))
        if machine.isOpen { layoutPanel() }
    }

    func tearDown() {
        handle(.hostLost)
        hoverWindow.orderOut(nil)
    }

    private func perform(_ effect: PanelEffect) {
        switch effect {
        case .startTimer(let kind, let delay):
            timers[kind]?.invalidate()
            timers[kind] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.timerFired(kind)) }
            }
        case .cancelTimer(let kind):
            timers[kind]?.invalidate()
            timers[kind] = nil
        case .open:
            show()
        case .close:
            hide()
        case .openPopover:
            onOpenPopover()
        }
    }

    // MARK: - Windows

    private func layoutHoverZone() {
        let zone = NotchGeometry.hoverZone(screenFrame: screen.frame, notch: ScreenCatalog.notch(of: screen))
        hoverWindow.setFrame(zone, display: false)
    }

    /// The content changed height (a taller generator, a status line): the
    /// panel keeps its top against the menu bar and grows or shrinks down.
    private func contentGrew() {
        guard machine.isOpen else { return }
        let size = hosting.fittingSize
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        let frame = NotchGeometry.panelFrame(
            screenFrame: screen.frame, menuBarHeight: ScreenCatalog.menuBarHeight(of: screen), notch: ScreenCatalog.notch(of: screen),
            width: preferences.width, contentHeight: size.height
        )
        panel.setFrame(frame, display: true)
    }

    private func layoutPanel() {
        hosting.rootView = PanelContent(model: model, width: preferences.width.points, header: header?(), showSettings: showSettings, quit: quit)
        let size = hosting.fittingSize
        let frame = NotchGeometry.panelFrame(
            screenFrame: screen.frame, menuBarHeight: ScreenCatalog.menuBarHeight(of: screen), notch: ScreenCatalog.notch(of: screen),
            width: preferences.width, contentHeight: size.height
        )
        panel.setFrame(frame, display: true)
    }

    private func show() {
        model.targetDisplay = display.id
        model.clearStatus()
        layoutPanel()
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
        // A click in one of the app's other windows (Settings) is outside too.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.hoverWindow { self.handle(.clickedOutside) }
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

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
        escapeMonitor = nil
    }
}

/// The panel's SwiftUI content in its card: glass, the top squared off
/// where it meets the menu bar, the bottom corners rounded.
struct PanelContent: View {
    let model: AppModel
    let width: CGFloat
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    var expandFinishes = false
    var expandFavorites = false

    var body: some View {
        WallpaperPanelView(model: model, attachedToNotch: true, width: width, header: header, showSettings: showSettings, quit: quit, expandFinishes: expandFinishes, expandFavorites: expandFavorites)
            .background(PanelBackdrop())
            .clipShape(NotchPanelShape())
    }
}

/// Glass or material behind the panel, with the notch panel's shape.
struct PanelBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        let style = SurfaceStyle(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        let shape = NotchPanelShape()
        Group {
            if previewRendering {
                // `ImageRenderer` draws no material: a translucent flat stands in.
                shape.fill(Brand.canvas.opacity(0.88))
            } else if #available(macOS 26, *), style.usesGlass {
                Color.clear.glassEffect(.regular, in: shape)
            } else if style.reduceTransparency {
                shape.fill(Brand.canvas)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(shape.strokeBorder(style.increasedContrast ? Brand.textPrimary.opacity(0.6) : Brand.borderSubtle.opacity(0.6), lineWidth: 1))
    }
}

/// Squared at the top, rounded at the bottom.
struct NotchPanelShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(Brand.Radius.panel, r.width / 2, r.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        path.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NotchPanelShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// The transparent view over the notch: enter, exit and click.
final class HoverZoneView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: () -> Void = {}
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
    override func mouseDown(with event: NSEvent) { onClick() }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the hosting view and reports the pointer entering and leaving,
/// and the content wanting another height.
final class PanelContainerView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onContentHeightChange: () -> Void = {}
    private var tracking: NSTrackingArea?
    private let hosting: NSView

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }

    /// SwiftUI resizes its hosting view's fitting size as the content
    /// changes; when it no longer matches the window, the controller
    /// re-frames the panel (which lays out again, and then matches).
    override func layout() {
        super.layout()
        if abs(hosting.fittingSize.height - bounds.height) > 0.5 { onContentHeightChange() }
    }
}
