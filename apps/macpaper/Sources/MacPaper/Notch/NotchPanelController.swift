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
    /// The menu-bar item's frame in screen coordinates, when it has one:
    /// on a display without a notch the column opens under it.
    private let statusItemFrame: () -> CGRect?

    private(set) var machine: PanelStateMachine
    private let hoverWindow: NSPanel
    private let panel: NSPanel
    /// The click-through strip that shades the menu-bar row above a
    /// notch-anchored column.
    private let shade: NSPanel
    private let hosting: NSHostingView<PanelContent>
    private var timers: [PanelTimer: Timer] = [:]
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var escapeMonitor: Any?

    var isOpen: Bool { machine.isOpen }

    /// The licensing wiring's header (the trial pill); nil draws nothing.
    let header: (() -> AnyView)?

    init(display: DisplayInfo, screen: NSScreen, model: AppModel, preferences: Preferences, header: (() -> AnyView)? = nil, statusItemFrame: @escaping () -> CGRect? = { nil }, onOpenPopover: @escaping () -> Void, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.display = display
        self.header = header
        self.screen = screen
        self.model = model
        self.preferences = preferences
        self.statusItemFrame = statusItemFrame
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
        // The column is dark in both appearances (PanelTheme).
        panel.appearance = NSAppearance(named: .darkAqua)

        shade = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        shade.isOpaque = false
        shade.backgroundColor = .clear
        shade.hasShadow = false
        shade.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        shade.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        shade.isReleasedWhenClosed = false
        shade.hidesOnDeactivate = false
        shade.isFloatingPanel = true
        // Visual only: the menu bar under it keeps every click.
        shade.ignoresMouseEvents = true
        shade.animationBehavior = .none
        shade.contentView = NSHostingView(rootView: MenuBarShade())

        let content = PanelContent(model: model, width: PanelMetrics.width(for: preferences.width), header: header?(), showSettings: showSettings, quit: quit)
        hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
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
            shade.orderOut(nil)
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

    /// What the column hangs from on this screen: the notch, the menu-bar
    /// item when it sits on this screen, else the top center.
    var anchor: PanelAnchor {
        let menuBar = ScreenCatalog.menuBarHeight(of: screen)
        if let notch = ScreenCatalog.notch(of: screen) { return .notch(notch, menuBarHeight: menuBar) }
        if let item = statusItemFrame(), screen.frame.intersects(item) { return .statusItem(item, menuBarHeight: menuBar) }
        return .topCenter(menuBarHeight: menuBar)
    }

    /// The column is a fixed height for the screen (most of it): sections
    /// switch without the window jumping. The content scrolls inside.
    private var columnHeight: CGFloat {
        PanelLayout.columnHeight(screenHeight: screen.frame.height, topInset: NotchGeometry.topInset(for: anchor))
    }

    /// The content wants another height: the column's height is the
    /// screen's, so nothing moves; kept for a screen too short for the
    /// cap, where the column follows the content down to it.
    private func contentGrew() {
        guard machine.isOpen else { return }
        let wanted = min(columnHeight, max(hosting.fittingSize.height, 0))
        guard abs(wanted - panel.frame.height) > 0.5, wanted < columnHeight else { return }
        layoutPanel()
    }

    private func layoutPanel() {
        let anchor = anchor
        let height = columnHeight
        let width = PanelMetrics.width(for: preferences.width)
        hosting.rootView = PanelContent(
            model: model, width: width, height: height, anchoredToNotch: anchor.isNotch, header: header?(),
            showSettings: showSettings, quit: quit, dismiss: { [weak self] in self?.handle(.escape) }
        )
        let frame = NotchGeometry.panelFrame(screenFrame: screen.frame, anchor: anchor, width: width, contentHeight: height)
        panel.setFrame(frame, display: true)
        if let strip = NotchGeometry.menuBarShadeFrame(screenFrame: screen.frame, anchor: anchor, panelFrame: frame) {
            shade.setFrame(strip, display: true)
        }
    }

    private var shadesMenuBar: Bool {
        NotchGeometry.menuBarShadeFrame(screenFrame: screen.frame, anchor: anchor, panelFrame: panel.frame) != nil
    }

    private func show() {
        model.targetDisplay = display.id
        model.clearStatus()
        layoutPanel()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let final = panel.frame
        let shades = shadesMenuBar
        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            if shades {
                shade.alphaValue = 1
                shade.orderFrontRegardless()
            }
        } else {
            panel.alphaValue = 0
            panel.setFrame(final.offsetBy(dx: 0, dy: 10), display: false)
            panel.orderFrontRegardless()
            if shades {
                shade.alphaValue = 0
                shade.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Brand.Motion.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
                if shades { shade.animator().alphaValue = 1 }
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
            shade.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Brand.Motion.fast
                panel.animator().alphaValue = 0
                shade.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.machine.isOpen else { return }
                    self.panel.orderOut(nil)
                    self.shade.orderOut(nil)
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

/// The column in its shape: the opaque dark ground, the top squared off
/// where it hangs from the notch (rounded all round under a menu-bar
/// item), the rim the design system specifies.
struct PanelContent: View {
    let model: AppModel
    let width: CGFloat
    var height: CGFloat? = nil
    /// Squared top corners: the column meets the notch.
    var anchoredToNotch = true
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    var dismiss: () -> Void = {}

    var body: some View {
        let shape = NotchPanelShape(squaredTop: anchoredToNotch)
        WallpaperPanelView(model: model, width: width, height: height, header: header, showSettings: showSettings, quit: quit, dismiss: dismiss)
            .background(PanelBackdrop(shape: shape))
            .clipShape(shape)
            .overlay(PanelRim(shape: shape))
    }
}

/// The ground behind the column: `PanelTheme.ground`, opaque in every
/// case (Reduce Transparency changes nothing, there is nothing to
/// reduce); under Increase Contrast the rim brightens.
struct PanelBackdrop: View {
    let shape: NotchPanelShape

    var body: some View {
        shape.fill(Brand.Panel.ground)
    }
}

/// The 1-point rim: neutral/700 on the ground, brighter under Increase
/// Contrast, and a hairline of light along the top edge where the column
/// meets the menu bar.
struct PanelRim: View {
    let shape: NotchPanelShape
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        shape.strokeBorder(contrast == .increased ? Brand.Panel.textPrimary.opacity(0.6) : Brand.Panel.rim, lineWidth: 1)
    }
}

/// The click-through strip over the menu-bar row above the column: the
/// column's black, at `PanelTheme.menuBarShadeAlpha`, so the row reads as
/// part of it while the menu bar keeps every click.
struct MenuBarShade: View {
    var body: some View {
        Rectangle().fill(Brand.Panel.ground.opacity(PanelTheme.menuBarShadeAlpha))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Squared at the top and rounded at the bottom on a notch; rounded all
/// round under a menu-bar item.
struct NotchPanelShape: InsettableShape {
    var squaredTop = true
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(Brand.Radius.panel, r.width / 2, r.height / 2)
        guard squaredTop else {
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r)
        }
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
