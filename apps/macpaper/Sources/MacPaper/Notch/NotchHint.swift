import AppKit
import MacPaperCore
import SwiftUI

/// The first-run glow under the notch (design/products/macpaper.md, "The
/// panel", first run): while the hint is armed (`NotchHint` in the core:
/// the first launches, until the notch has opened the panel once) a soft
/// tangerine glow hangs under the notch and pulses whenever the pointer
/// comes within `PanelLayout.hintReach` of it, so the hover zone is found
/// without being told. A click-through window on the menu bar's level,
/// so it covers nothing; the pointer is read by a global mouse-moved
/// monitor, which needs no permission (only keyboard monitors do), and
/// only while the hint is armed.
final class NotchHintController {
    private let flags: any FlagStore
    private var screen: NSScreen
    private var notch: CGRect
    private let window: NSPanel
    private var monitor: Any?
    private var isNear = false
    private var panelIsOpen = false
    private var done = false

    /// Off while the notch panel is off or this display does not host it.
    var isEnabled = true {
        didSet { if isEnabled != oldValue { refresh() } }
    }

    init(screen: NSScreen, notch: CGRect, flags: any FlagStore) {
        self.flags = flags
        self.screen = screen
        self.notch = notch
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: NotchGlow())
        window.alphaValue = 0
        layout()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    deinit {
        MainActor.assumeIsolated { tearDown() }
    }

    func update(screen: NSScreen, notch: CGRect) {
        self.screen = screen
        self.notch = notch
        layout()
    }

    /// The notch opened the panel: the hint is done, this launch and every
    /// later one.
    func markUsed() {
        NotchHint.markUsed(store: flags)
        done = true
        refresh()
    }

    func panelOpened() {
        panelIsOpen = true
        refresh()
    }

    func panelClosed() {
        panelIsOpen = false
        pointerMoved()
    }

    func tearDown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window.orderOut(nil)
    }

    private func layout() {
        window.setFrame(NotchGeometry.hintGlowFrame(screenFrame: screen.frame, notch: notch), display: false)
    }

    private func pointerMoved() {
        let near = NotchGeometry.hintZone(screenFrame: screen.frame, notch: notch).contains(NSEvent.mouseLocation)
        guard near != isNear else { return }
        isNear = near
        refresh()
    }

    /// Shown while the pointer is near, the panel is closed and the hint
    /// still applies; faded in and out over the standard duration.
    private func refresh() {
        let shown = isEnabled && isNear && !panelIsOpen && !done
        if shown { window.orderFrontRegardless() }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            window.alphaValue = shown ? 1 : 0
            if !shown { window.orderOut(nil) }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Brand.Motion.standard
                window.animator().alphaValue = shown ? 1 : 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window.alphaValue == 0 else { return }
                    self.window.orderOut(nil)
                }
            })
        }
    }
}

/// The glow itself: a tangerine light hanging from the top edge (the
/// notch's bottom) — a bright seam along the edge and a soft fall-off over
/// `PanelLayout.hintDepth` — pulsing gently; under Reduce Motion it holds
/// still. Purely decorative, so it hides from assistive technology.
struct NotchGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewRendering) private var previewRendering
    @State private var lit = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            ZStack(alignment: .top) {
                // The fall-off: a half-ellipse of light under the edge.
                EllipticalGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.9), location: 0),
                        .init(color: Brand.Panel.accent.opacity(0.7), location: 0.3),
                        .init(color: Brand.Panel.accent.opacity(0), location: 1),
                    ],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
                )
                .frame(width: width, height: height * 2)
                .offset(y: -height)
                // The seam: the notch's own width, a hair under the edge.
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(0, width - 2 * PanelLayout.hintReach), height: 3)
                    .blur(radius: 1.2)
            }
            .frame(width: width, height: height, alignment: .top)
            .clipped()
        }
        .opacity(reduceMotion || previewRendering ? 0.85 : (lit ? 1 : 0.4))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: lit)
        .onAppear { lit = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
