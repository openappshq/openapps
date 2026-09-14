import AppKit
import OpenReactionCore
import SwiftUI

/// Floating panel that never activates OpenReaction, so System Settings keeps
/// focus while the user follows the guide. It still takes clicks.
private final class FloatingGuidePanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Docks a "Turn on OpenReaction" guide beside the System Settings window
/// after the user is sent there.
///
/// The window frame comes from `CGWindowListCopyWindowInfo`, whose bounds and
/// owner PID are readable without Screen Recording access (window titles are
/// not, and are not used). Without a window the guide sits center-right. It
/// closes when the permission is granted, System Settings quits, or its
/// window stays gone for two seconds.
@MainActor
final class GuidePanelController {
    var onNotListed: ((PermissionKind) -> Void)?

    private let panel = FloatingGuidePanel()
    private let permissions: PermissionMonitor
    private var kind: PermissionKind?
    private var timer: Timer?
    private var shownAt = Date.distantPast
    private var foundWindow = false
    private var windowMissingSince: Date?
    private var terminateObserver: NSObjectProtocol?

    private nonisolated static let settingsBundleIdentifier = "com.apple.systempreferences"
    /// System Settings can take a moment to launch and open the pane.
    private static let launchGrace: TimeInterval = 8
    private static let missingWindowGrace: TimeInterval = 2

    init(permissions: PermissionMonitor) {
        self.permissions = permissions
    }

    func show(_ kind: PermissionKind) {
        guard !permissions.snapshot.reportedGranted.contains(kind) else { return }
        self.kind = kind
        let hostingView = ClickThroughHostingView(rootView: GuideView(
            kind: kind,
            onNotListed: { [weak self] in
                self?.hide()
                self?.onNotListed?(kind)
            },
            onClose: { [weak self] in self?.hide() }
        ))
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        shownAt = Date()
        foundWindow = false
        windowMissingSince = nil
        position(settingsFrame: Self.settingsWindowFrame())

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reduceMotion ? Brand.Motion.fast : Brand.Motion.standard
                panel.animator().alphaValue = 1
            }
        }

        permissions.setFastPolling(true, reason: "guide")
        if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if terminateObserver == nil {
            terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.settingsBundleIdentifier else { return }
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        terminateObserver = nil
        kind = nil
        permissions.setFastPolling(false, reason: "guide")
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func tick() {
        guard let kind else { return }
        if permissions.snapshot.reportedGranted.contains(kind) {
            hide()
            return
        }
        let settingsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleIdentifier).isEmpty
        let frame = Self.settingsWindowFrame()
        let now = Date()
        if frame != nil {
            foundWindow = true
            windowMissingSince = nil
        } else if foundWindow || (!settingsRunning && now.timeIntervalSince(shownAt) > Self.launchGrace) {
            let since = windowMissingSince ?? now
            windowMissingSince = since
            if now.timeIntervalSince(since) >= Self.missingWindowGrace {
                hide()
                return
            }
        }
        position(settingsFrame: frame)
    }

    private func position(settingsFrame: CGRect?) {
        let size = panel.frame.size
        let frame = GuidePlacement.frame(
            size: size,
            beside: settingsFrame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        if frame.integral != panel.frame.integral {
            panel.setFrame(frame, display: true)
        }
    }

    /// Largest on-screen, normal-level window owned by System Settings, in
    /// AppKit coordinates.
    private static func settingsWindowFrame() -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleIdentifier).map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list
            .filter { info in
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { return false }
                return (info[kCGWindowLayer as String] as? Int) == 0
            }
            .compactMap { info -> CGRect? in
                guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }
            .filter { $0.width > 200 && $0.height > 200 }
            .max { $0.width * $0.height < $1.width * $1.height }
            .map { PanelPlacement.appKitRect(fromQuartz: $0, primaryScreenHeight: primaryHeight) }
    }
}

private struct GuideView: View {
    let kind: PermissionKind
    let onNotListed: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            HStack {
                MonoLabel("OpenReaction")
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close guide")
            }
            Text("Turn on OpenReaction")
                .font(Brand.display(22))
                .foregroundStyle(Brand.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Find OpenReaction in the \(kind.title) list and switch it on. This closes by itself once it works.")
                .font(Brand.body(13))
                .lineSpacing(2)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ToggleRowIllustration()
            Button("I don't see it", action: onNotListed)
                .buttonStyle(LinkButtonStyle())
        }
        .padding(Brand.Space.s16)
        .frame(width: 290)
        .cardSurface()
        .padding(1)
    }
}

/// Short-lived pointer under the real status item, shown when onboarding
/// finishes so the user knows where OpenReaction went.
@MainActor
final class MenuBarHintController {
    private let panel = FloatingGuidePanel()
    private var hideTask: Task<Void, Never>?

    /// - Parameter frame: The status item button's window frame, AppKit coordinates.
    func show(below frame: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return }
        let hostingView = ClickThroughHostingView(rootView: MenuBarHintView { [weak self] in self?.hide() })
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 4)
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

private struct MenuBarHintView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Brand.Space.s4) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 12))
                .foregroundStyle(Brand.accentSolid)
            HStack(spacing: Brand.Space.s8) {
                Text("OpenReaction lives here")
                    .font(Brand.body(13, weight: 600))
                    .foregroundStyle(Brand.accentOn)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.accentOn)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Brand.Space.s12)
            .frame(height: 32)
            .background(Brand.accentSolid, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        }
        .padding(Brand.Space.s4)
        .accessibilityElement(children: .combine)
    }
}
