import AppKit
import OpenReactionCore
import SwiftUI

/// Floating panel that never activates OpenReaction, so System Settings keeps
/// focus while the user follows the guide. It still takes clicks — and a drag
/// from the permission helper's icon.
final class FloatingGuidePanel: NSPanel {
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
