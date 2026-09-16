import AppKit
import MacPaperCore
import SwiftUI

/// One clock face per display on the wallpaper layer: a window one level
/// above the desktop picture and below the icons, that ignores the mouse,
/// joins every Space and is hidden while the display's front app is
/// fullscreen. Palette-matched to the document the display shows; ticks
/// once a second; under Reduce Motion the second hand steps instead of
/// sweeping (it never sweeps anyway: one draw per second).
final class ClockController {
    private let model: AppModel
    private let preferences: Preferences
    private var windows: [DisplayID: NSWindow] = [:]
    private var timer: Timer?
    private let time = ClockTime()
    private let fullscreen = FullscreenWatcher()
    private var observers: [NSObjectProtocol] = []

    @Observable
    final class ClockTime {
        var now = Date()
    }

    init(model: AppModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        fullscreen.onChange = { [weak self] in self?.updateVisibility() }
        observeChanges({ [preferences] in _ = preferences.clockStyle; _ = preferences.clockPosition; _ = preferences.clockSize }, onChange: { [weak self] in self?.rebuild() })
        observeChanges({ [model] in _ = model.appliedState }, onChange: { [weak self] in self?.rebuild() })
        rebuild()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            for window in windows.values { window.orderOut(nil) }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    var isOn: Bool { preferences.clockStyle != .off }

    /// A window per display while the clock is on; none otherwise.
    func rebuild() {
        guard isOn else {
            for window in windows.values { window.orderOut(nil) }
            windows.removeAll()
            timer?.invalidate()
            timer = nil
            fullscreen.watchedDisplays = []
            return
        }
        var kept: [DisplayID: NSWindow] = [:]
        for screen in NSScreen.screens {
            guard let id = ScreenCatalog.displayID(of: screen) else { continue }
            let frame = ClockPalette.frame(in: screen.frame, position: preferences.clockPosition, size: preferences.clockSize, menuBarHeight: ScreenCatalog.menuBarHeight(of: screen))
            let window = windows[id] ?? Self.makeWindow()
            let side: Side = model.systemAppearance()
            let palette = ClockPalette.make(for: model.appliedState.wallpaper(for: id), side: side)
            window.contentView = NSHostingView(rootView: ClockFace(time: time, style: preferences.clockStyle, palette: palette))
            window.setFrame(frame, display: true)
            kept[id] = window
        }
        for (id, window) in windows where kept[id] == nil { window.orderOut(nil) }
        windows = kept
        fullscreen.watchedDisplays = Array(kept.keys)
        updateVisibility()
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.time.now = Date() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func updateVisibility() {
        for (id, window) in windows {
            if fullscreen.isFullscreen(display: id) {
                window.orderOut(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Just above the desktop picture, below the desktop icons.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        return window
    }
}

/// The face: analog with hour and minute hands and a stepping second hand,
/// or a digital readout in the display type. Colors from `ClockPalette`.
struct ClockFace: View {
    let time: ClockController.ClockTime
    let style: ClockStyle
    let palette: ClockPalette

    var body: some View {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: time.now)
        GeometryReader { proxy in
            let edge = min(proxy.size.width, proxy.size.height)
            ZStack {
                switch style {
                case .analog:
                    analog(components, edge: edge)
                case .digital:
                    Text(String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0))
                        .font(Brand.display(edge * 0.34))
                        .foregroundStyle(color(palette.face))
                        .shadow(color: .black.opacity(0.25), radius: edge * 0.02, y: edge * 0.01)
                case .off:
                    EmptyView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }

    private func analog(_ components: DateComponents, edge: CGFloat) -> some View {
        let hour = Double(components.hour ?? 0), minute = Double(components.minute ?? 0), second = Double(components.second ?? 0)
        return ZStack {
            Circle()
                .strokeBorder(color(palette.ticks), lineWidth: edge * 0.012)
            ForEach(0..<12, id: \.self) { tick in
                Capsule()
                    .fill(color(palette.ticks))
                    .frame(width: edge * 0.012, height: tick % 3 == 0 ? edge * 0.08 : edge * 0.04)
                    .offset(y: -edge * 0.44)
                    .rotationEffect(.degrees(Double(tick) * 30))
            }
            hand(length: 0.26, width: 0.05, angle: (hour.truncatingRemainder(dividingBy: 12) + minute / 60) * 30, color: palette.face, edge: edge)
            hand(length: 0.38, width: 0.035, angle: (minute + second / 60) * 6, color: palette.face, edge: edge)
            hand(length: 0.42, width: 0.012, angle: second * 6, color: palette.hands, edge: edge)
            Circle().fill(color(palette.hands)).frame(width: edge * 0.05, height: edge * 0.05)
        }
    }

    private func hand(length: CGFloat, width: CGFloat, angle: Double, color: RGBAColor, edge: CGFloat) -> some View {
        Capsule()
            .fill(self.color(color))
            .frame(width: edge * width, height: edge * length)
            .offset(y: -edge * length / 2)
            .rotationEffect(.degrees(angle))
            .shadow(color: .black.opacity(0.2), radius: edge * 0.01, y: edge * 0.005)
    }

    private func color(_ c: RGBAColor) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
