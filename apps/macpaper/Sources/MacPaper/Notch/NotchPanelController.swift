import AppKit
import MacPaperCore
import SwiftUI

/// One display's panel: the column itself, a borderless non-activating
/// `NSPanel`, and — on a display that hosts the notch panel — a transparent
/// hover window over the notch (or the hot edge of a display without one)
/// that reports the pointer and clicks. The column hangs from whatever
/// opened it (`PanelAnchor.resolve`): the notch for a hover or a click on
/// it, the menu-bar item for a click on the item, and is placed by
/// `NotchGeometry.panelFrame` inside the display's visible frame. Every
/// open or close goes through the core's `PanelStateMachine`; this class
/// only owns the windows, the timers and the monitors the machine's
/// effects ask for.
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
/// - The column's height follows its content (`min(content, cap)`): the
///   view reports its natural height as it lays out, and the window
///   follows with its top edge fixed.
final class NotchPanelController {
    let display: DisplayInfo
    private(set) var screen: NSScreen
    private let model: AppModel
    private let preferences: Preferences
    private let showSettings: () -> Void
    private let quit: () -> Void
    /// The menu-bar item's frame in screen coordinates, when it has one:
    /// a click on the item and the hotkey hang the column under it.
    private let statusItemFrame: () -> CGRect?
    /// The window the menu-bar item lives in: a click there is the item's
    /// own toggle (delivered on mouse-up), never a click outside.
    private let statusItemWindow: () -> NSWindow?
    /// The licensing wiring's header (the trial pill), read at every
    /// layout; nil draws nothing.
    private let header: () -> AnyView?

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
    /// The first-run glow under the notch; nil on a display without one
    /// or once the hint is done.
    private var hint: NotchHintController?
    /// What the content last asked for; nil before the first layout.
    private var naturalHeight: CGFloat?

    var isOpen: Bool { machine.isOpen }

    /// Whether this display hosts the notch panel: the hover zone is live
    /// and the hotkey drops the column from the notch. A display that does
    /// not still opens the column under the menu-bar item.
    var hostsNotch: Bool {
        didSet { if hostsNotch != oldValue { layoutHoverZone() } }
    }

    init(display: DisplayInfo, screen: NSScreen, model: AppModel, preferences: Preferences, hostsNotch: Bool, header: @escaping () -> AnyView? = { nil }, statusItemFrame: @escaping () -> CGRect? = { nil }, statusItemWindow: @escaping () -> NSWindow? = { nil }, hintFlags: (any FlagStore)? = nil, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.display = display
        self.header = header
        self.screen = screen
        self.model = model
        self.preferences = preferences
        self.hostsNotch = hostsNotch
        self.statusItemFrame = statusItemFrame
        self.statusItemWindow = statusItemWindow
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
        // Under the menu bar's own window: it shows through the bar's
        // translucency and never tints a menu item.
        shade.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        shade.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        shade.isReleasedWhenClosed = false
        shade.hidesOnDeactivate = false
        shade.isFloatingPanel = true
        // Visual only: the menu bar under it keeps every click.
        shade.ignoresMouseEvents = true
        shade.animationBehavior = .none
        shade.contentView = NSHostingView(rootView: MenuBarShade())

        let content = PanelContent(model: model, width: PanelMetrics.width(for: preferences.width), header: header(), showSettings: showSettings, quit: quit)
        hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let container = PanelContainerView(hosting: hosting)
        panel.contentView = container

        let zone = HoverZoneView(frame: .zero)
        hoverWindow.contentView = zone
        zone.onEnter = { [weak self] in self?.handle(.pointerEnteredNotch) }
        zone.onExit = { [weak self] in self?.handle(.pointerLeftNotch) }
        zone.onClick = { [weak self] in self?.handle(.notchClicked) }
        container.onEnter = { [weak self] in self?.handle(.pointerEnteredPanel) }
        container.onExit = { [weak self] in self?.handle(.pointerLeftPanel) }

        if let hintFlags, let notch = ScreenCatalog.notch(of: screen), NotchHint.isArmed(store: hintFlags) {
            hint = NotchHintController(screen: screen, notch: notch, flags: hintFlags)
        }
        layoutHoverZone()
    }

    deinit {
        MainActor.assumeIsolated {
            for timer in timers.values { timer.invalidate() }
            removeMonitors()
            hoverWindow.orderOut(nil)
            panel.orderOut(nil)
            shade.orderOut(nil)
            hint?.tearDown()
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
        if let notch = ScreenCatalog.notch(of: screen) {
            hint?.update(screen: screen, notch: notch)
        } else {
            hint?.tearDown()
            hint = nil
        }
        if machine.isOpen { layoutPanel(animated: false) }
    }

    func settingsChanged() {
        handle(.settingsChanged(preferences.panelSettings))
        hint?.isEnabled = preferences.notchEnabled && hostsNotch
        if machine.isOpen { layoutPanel(animated: false) }
    }

    func tearDown() {
        handle(.hostLost)
        hoverWindow.orderOut(nil)
        hint?.tearDown()
        hint = nil
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
        }
    }

    // MARK: - Windows

    /// The hover zone is live only where this display hosts the notch
    /// panel; a display used from the menu bar keeps its window ordered
    /// out, so nothing at its top edge reacts.
    private func layoutHoverZone() {
        let zone = NotchGeometry.hoverZone(screenFrame: screen.frame, notch: ScreenCatalog.notch(of: screen))
        hoverWindow.setFrame(zone, display: false)
        if hostsNotch {
            hoverWindow.orderFrontRegardless()
        } else {
            hoverWindow.orderOut(nil)
        }
        hint?.isEnabled = preferences.notchEnabled && hostsNotch
    }

    /// Where the column hangs from now: from what opened it. Before the
    /// first open (and for a re-layout), the notch where the panel may
    /// show, else the item.
    var anchor: PanelAnchor {
        let item = statusItemFrame().flatMap { screen.frame.intersects($0) ? $0 : nil }
        return PanelAnchor.resolve(
            opener: machine.openedBy ?? .hotkey, notch: ScreenCatalog.notch(of: screen), item: item,
            notchPanelMayShow: hostsNotch && machine.canShow
        )
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
        let anchor = anchor
        let height = columnHeight
        let width = PanelMetrics.width(for: preferences.width)
        hosting.rootView = PanelContent(
            model: model, width: width, height: height, anchoredToNotch: anchor.isNotch, header: header(),
            showSettings: showSettings, quit: quit, dismiss: { [weak self] in self?.handle(.escape) },
            onNaturalHeight: { [weak self] in self?.contentHeightChanged($0) }
        )
        let frame = NotchGeometry.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, anchor: anchor, width: width, contentHeight: height)
        let strip = NotchGeometry.menuBarShadeFrame(screenFrame: screen.frame, anchor: anchor, panelFrame: frame)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Brand.Motion.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        if let strip { shade.setFrame(strip, display: true) }
    }

    private var shadesMenuBar: Bool {
        NotchGeometry.menuBarShadeFrame(screenFrame: screen.frame, anchor: anchor, panelFrame: panel.frame) != nil
    }

    private func show() {
        model.targetDisplay = display.id
        model.clearStatus()
        hint?.panelOpened()
        if let opener = machine.openedBy, opener == .hover || opener == .click, anchor.isNotch {
            // The notch has been found: the hint's job is done.
            hint?.markUsed()
        }
        // The content's natural height, measured before the window shows,
        // so the column opens at its final size; the view's own report
        // refines it afterwards.
        let width = PanelMetrics.width(for: preferences.width)
        naturalHeight = PanelMetrics.naturalHeight(of: PanelContent(model: model, width: width, header: header(), showSettings: {}, quit: {}))
        layoutPanel(animated: false)
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
        hint?.panelClosed()
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
        // A click in one of the app's other windows (Settings) is outside
        // too; not one on the menu-bar item, whose mouse-up toggles.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.clickIsOutside(window: event.window, own: [self.panel, self.hoverWindow, self.statusItemWindow()]) { self.handle(.clickedOutside) }
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
    /// window but the panel's own, the hover zone's and the menu-bar
    /// item's (whose click is the item's toggle, on mouse-up).
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

/// The column in its shape: the opaque dark ground, the top squared off
/// where it hangs from the notch (rounded all round under a menu-bar
/// item), the rim the design system specifies.
struct PanelContent: View {
    let model: AppModel
    let width: CGFloat
    /// The column's height; nil sizes to the content (the harness, and the
    /// measurement the window takes before it shows).
    var height: CGFloat? = nil
    /// Squared top corners: the column meets the notch.
    var anchoredToNotch = true
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    var dismiss: () -> Void = {}
    /// The content's natural height as it lays out (`WallpaperPanelView`).
    var onNaturalHeight: ((CGFloat) -> Void)? = nil

    var body: some View {
        let shape = NotchPanelShape(squaredTop: anchoredToNotch)
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

/// The click-through strip under the menu-bar row above the column (below
/// the menu bar's window level, so it shows through the bar's translucency
/// and never tints an item): the column's black at
/// `PanelTheme.menuBarShadeAlpha`, so the row reads as part of it while
/// the menu bar keeps every click.
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

/// Holds the hosting view and reports the pointer entering and leaving.
final class PanelContainerView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
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
}
