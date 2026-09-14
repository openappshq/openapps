import AppKit
import SwiftUI

/// Shown when a stop (pause, license lock, relaunch, quit) has been waiting
/// on held typing for longer than the replay bound. The window is
/// non-activating and floats, and input aimed at OpenReaction's own windows
/// is never held, so it stays usable while everything else waits.
@MainActor
final class StuckInputPanel {
    enum Reason {
        /// The posting queue has not run the replay within the bound.
        case slow
        /// The field the input was typed in is no longer focused.
        case fieldChanged
    }

    private var panel: NSPanel?
    private let keepWaiting: () -> Void
    private let discard: () -> Void

    init(keepWaiting: @escaping () -> Void, discard: @escaping () -> Void) {
        self.keepWaiting = keepWaiting
        self.discard = discard
    }

    func show(reason: Reason) {
        if let panel {
            (panel.contentView as? NSHostingView<StuckInputView>)?.rootView.reason = reason
            panel.orderFrontRegardless()
            return
        }
        let view = StuckInputView(
            reason: reason,
            keepWaiting: { [weak self] in
                self?.close()
                self?.keepWaiting()
            },
            discard: { [weak self] in
                self?.close()
                self?.discard()
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "OpenReaction"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

struct StuckInputView: View {
    var reason: StuckInputPanel.Reason
    let keepWaiting: () -> Void
    let discard: () -> Void

    private var title: String {
        switch reason {
        case .slow: "Typing is still being restored"
        case .fieldChanged: "Held typing is waiting for its field"
        }
    }

    private var explanation: String {
        switch reason {
        case .slow:
            "OpenReaction held back a few keystrokes while it was stopping and is waiting to put them back where you typed them. That is taking unusually long. You can keep waiting, or discard those keystrokes and let OpenReaction stop now."
        case .fieldChanged:
            "OpenReaction held back a few keystrokes while it was stopping, and the field you typed them in is no longer focused. They are never typed anywhere else: switch back to that field and they go in, or discard them and let OpenReaction stop now."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            Text(title)
                .font(Brand.body(15, weight: 600))
            Text(explanation)
                .font(Brand.body(13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Discard held typing", action: discard)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Keep waiting", action: keepWaiting)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Brand.Space.s16)
        .frame(width: 420)
        .background(Brand.surface)
    }
}
