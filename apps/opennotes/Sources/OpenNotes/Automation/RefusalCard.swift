import AppKit
import OpenNotesCore
import SwiftUI

/// What a refused `opennotes://` link shows while read-only: a card the
/// shape and color of a note, docked where the deck is, saying writing
/// waits for a license (LICENSING.md, "What says so"). Nothing was
/// written. The footer line opens Settings → License; a click anywhere
/// else, or ten seconds, puts it away.
struct RefusalCard: View {
    let notice: String
    let color: NoteColor
    let license: LicenseStatus
    var dismiss: () -> Void = {}

    static let size = CGSize(width: 320, height: 150)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LicensePillHeader(license: license)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Waits for a license")
                    .font(Brand.body(18, weight: 600))
                    .foregroundStyle(Brand.noteInk)
                Text("This link wanted to write a note. Your notes stay readable; nothing was changed.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.noteInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Button(action: license.openLicense) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                    Text(notice)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .font(Brand.mono(10))
                .foregroundStyle(Brand.noteInkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Opens License settings")
            .accessibilityLabel("Read-only: \(notice)")
            .accessibilityHint("Opens License settings")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.05))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.face(color), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenNotes: writing waits for a license")
    }
}

/// The card in its own small panel beside the deck's edge, above every
/// window like the deck, never taking focus; put away by a click on it
/// or after ten seconds. One at a time: a second refusal replaces the
/// first.
@MainActor
final class RefusalPanel {
    private var panel: NSPanel?
    private var timer: Timer?
    static let duration: TimeInterval = 10

    func show(notice: String, color: NoteColor, side: DeckSide, license: LicenseStatus) {
        dismiss()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = DeckPanelController.level
        panel.collectionBehavior = DeckPanelController.collectionBehavior
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setAccessibilityLabel("OpenNotes: writing waits for a license")
        let card = RefusalCard(notice: notice, color: color, license: license) { [weak self] in self?.dismiss() }
        let margin: CGFloat = 24
        let hosting = NSHostingView(rootView: card.padding(margin))
        panel.contentView = hosting
        let size = CGSize(width: RefusalCard.size.width + 2 * margin, height: RefusalCard.size.height + 2 * margin)
        // Beside the deck: the pointer's screen, the deck's edge, centred.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let x = side == .right ? visible.maxX - size.width - DeckMetrics().tabWidth : visible.minX + DeckMetrics().tabWidth
        let y = (visible.midY - size.height / 2).rounded()
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
