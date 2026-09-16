import AppKit
import OpenReactionCore
import SwiftUI

// MARK: - Model

/// When the drag-to-grant helper is on screen and which permission it names.
/// Pure rules, apart from the panel: the controller applies every answer.
///
/// It shows for one permission at a time and only while that permission is
/// not granted; it leaves when the permission is reported granted, when the
/// guide moves to another step or closes, and when the user closes it.
struct PermissionHelperModel: Equatable {
    private(set) var kind: PermissionKind?

    var isShown: Bool { kind != nil }

    /// Asked to show for `kind`. Refused, and nothing changes, while `kind`
    /// is already granted — there is nothing to drag in for.
    @discardableResult
    mutating func show(_ kind: PermissionKind, granted: Set<PermissionKind>) -> Bool {
        guard !granted.contains(kind) else { return false }
        self.kind = kind
        return true
    }

    /// Every poll of the permissions. Returns whether the helper just hid
    /// because its permission was granted.
    @discardableResult
    mutating func permissionsChanged(granted: Set<PermissionKind>) -> Bool {
        guard let kind, granted.contains(kind) else { return false }
        self.kind = nil
        return true
    }

    /// The guide moved to `step`: the helper belongs to a permission step and
    /// leaves with it. Returns whether it just hid.
    @discardableResult
    mutating func guideMoved(to step: OnboardingStep) -> Bool {
        guard let kind, step.permission != kind else { return false }
        self.kind = nil
        return true
    }

    /// The guide window closed, or the user closed the helper.
    mutating func close() {
        kind = nil
    }
}

// MARK: - Drag payload

/// What the helper's icon puts on the pasteboard: the app bundle as a file
/// URL, the same thing Finder offers when the app is dragged from there, so
/// System Settings' permission lists accept it.
struct AppDragPayload {
    let url: URL

    /// The running app's bundle.
    static var app: AppDragPayload { AppDragPayload(url: Bundle.main.bundleURL) }

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }
}

/// The app icon as a drag source. It starts a drag from the first click even
/// while its panel is not key — the helper never activates OpenReaction, so
/// System Settings stays in front and the drop lands in its list.
final class AppIconDragView: NSView, NSDraggingSource {
    let payload: AppDragPayload
    let image: NSImage
    var onDragBegan: ((URL) -> Void)?
    private var pressLocation: NSPoint?

    private static let dragThreshold: CGFloat = 4

    init(payload: AppDragPayload, image: NSImage) {
        self.payload = payload
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("OpenReaction app icon. Drag it into the list in System Settings.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The panel moves by its background; the icon must not.
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let moved = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard moved >= Self.dragThreshold else { return }
        pressLocation = nil
        let item = NSDraggingItem(pasteboardWriter: payload.pasteboardItem())
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        onDragBegan?(payload.url)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: [.copy, .link, .generic]
        case .withinApplication: []
        @unknown default: []
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// `AppIconDragView` in SwiftUI.
private struct AppIconDragSource: NSViewRepresentable {
    let payload: AppDragPayload
    let image: NSImage
    let onDragBegan: ((URL) -> Void)?

    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView(payload: payload, image: image)
        view.onDragBegan = onDragBegan
        return view
    }

    func updateNSView(_ view: AppIconDragView, context: Context) {
        view.onDragBegan = onDragBegan
    }
}

// MARK: - Controller

/// The drag-to-grant helper: a small floating panel next to System Settings
/// with the app icon to drag into the permission list, shown whenever the
/// guide sends the user there. Finding OpenReaction in the list — or adding
/// it with the + button and a file dialog — is the hard part of granting a
/// permission; dragging the icon in is one move.
///
/// The panel never activates OpenReaction, so System Settings keeps focus
/// while the drag lands in it. The window frame comes from
/// `CGWindowListCopyWindowInfo`, whose bounds and owner PID are readable
/// without Screen Recording access (window titles are not, and are not
/// used). Without a window the helper sits in the bottom-right corner of the
/// main screen. It closes when the permission is granted, the guide moves on
/// or closes, the user closes it, System Settings quits, or its window stays
/// gone for two seconds.
@MainActor
final class PermissionHelperController {
    /// "Not working? Reset" — the guide's own reset, so the marker that
    /// brings the guide back after macOS reopens the app is set too.
    var onReset: ((PermissionKind) -> Void)?
    /// A drag started from the icon, carrying this URL.
    var onDragBegan: ((URL) -> Void)?
    /// Off in the preview harness, where System Settings is never opened:
    /// the helper then stays until it is closed.
    var followsSystemSettings = true
    /// Off in the preview harness: the fade is a window-server animation
    /// that never settles while the display is off (a render over SSH), and
    /// a capture wants the settled panel.
    var fadesIn = true

    private(set) var model = PermissionHelperModel()
    private let panel = FloatingGuidePanel()
    private let permissions: PermissionMonitor
    private let payload: AppDragPayload
    private var timer: Timer?
    private var shownAt = Date.distantPast
    private var foundWindow = false
    private var windowMissingSince: Date?
    private var terminateObserver: NSObjectProtocol?

    private nonisolated static let settingsBundleIdentifier = "com.apple.systempreferences"
    /// System Settings can take a moment to launch and open the pane.
    private static let launchGrace: TimeInterval = 8
    private static let missingWindowGrace: TimeInterval = 2

    init(permissions: PermissionMonitor, payload: AppDragPayload = .app) {
        self.permissions = permissions
        self.payload = payload
    }

    var isVisible: Bool { panel.isVisible }
    var kind: PermissionKind? { model.kind }
    /// The panel itself, for the preview harness's captures.
    var window: NSWindow { panel }

    func show(_ kind: PermissionKind) {
        guard model.show(kind, granted: permissions.snapshot.reportedGranted) else { return }
        let hostingView = ClickThroughHostingView(rootView: PermissionHelperView(
            kind: kind,
            payload: payload,
            permissions: permissions,
            onDragBegan: { [weak self] url in self?.onDragBegan?(url) },
            onReset: { [weak self] in self?.onReset?(kind) },
            onClose: { [weak self] in self?.close() }
        ))
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        shownAt = Date()
        foundWindow = false
        windowMissingSince = nil
        position(settingsFrame: Self.settingsWindowFrame())

        if !panel.isVisible {
            if fadesIn {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.reduceMotion ? Brand.Motion.fast : Brand.Motion.standard
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }

        permissions.setFastPolling(true, reason: "helper")
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
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    /// The guide moved to `step`.
    func guideMoved(to step: OnboardingStep) {
        if model.guideMoved(to: step) { dismiss() }
    }

    /// The guide window closed, or the user closed the helper.
    func close() {
        model.close()
        dismiss()
    }

    private func dismiss() {
        timer?.invalidate()
        timer = nil
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        terminateObserver = nil
        permissions.setFastPolling(false, reason: "helper")
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func tick() {
        guard model.isShown else { return }
        if model.permissionsChanged(granted: permissions.snapshot.reportedGranted) {
            dismiss()
            return
        }
        guard followsSystemSettings else { return }
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
                close()
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

// MARK: - View

private struct PermissionHelperView: View {
    static let width: CGFloat = 300

    let kind: PermissionKind
    let payload: AppDragPayload
    let permissions: PermissionMonitor
    let onDragBegan: (URL) -> Void
    let onReset: () -> Void
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
                .accessibilityLabel("Close helper")
            }
            HStack(alignment: .top, spacing: Brand.Space.s16) {
                icon
                VStack(alignment: .leading, spacing: Brand.Space.s8) {
                    Text("Drag this icon into the list, then turn it on")
                        .font(Brand.body(14, weight: 600))
                        .lineSpacing(2)
                        .foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("The \(kind.title) list in System Settings. This closes by itself once it works.")
                        .font(Brand.body(13))
                        .lineSpacing(2)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(resetInProgress ? "Resetting…" : "Not working? Reset", action: onReset)
                .buttonStyle(LinkButtonStyle())
                .disabled(resetInProgress || !permissions.canReset)
                .accessibilityHint("Removes OpenReaction's old \(kind.title) entry so it can be added again.")
        }
        .padding(Brand.Space.s16)
        .frame(width: Self.width)
        .cardSurface()
        .padding(1)
    }

    private var icon: some View {
        AppIconDragSource(payload: payload, image: iconImage, onDragBegan: onDragBegan)
            .frame(width: 64, height: 64)
            .padding(Brand.Space.s4)
            .background {
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Brand.borderControl)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.accentOn)
                    .padding(4)
                    .background(Brand.accentSolid, in: Circle())
                    .offset(x: 6, y: 6)
                    .accessibilityHidden(true)
            }
    }

    private var resetInProgress: Bool { permissions.resetInProgress == kind }

    private var iconImage: NSImage {
        NSApp.applicationIconImage ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
