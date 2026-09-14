import AppKit
import OpenReactionCore
import SwiftUI

/// Shows the picker over a colorful window without the event tap or any
/// permissions, for visual checks: `OpenReaction --preview-picker`.
/// ← → move the selection while the preview window is focused.
@MainActor
final class PreviewHarness {
    private let window: NSWindow
    private let picker = PickerPanelController()
    private var keyMonitor: Any?

    init(provider: any SuggestionProvider, dataSourceSummary: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("PREVIEW_EMOJI_DATA \(dataSourceSummary)")
        let frame = NSRect(x: 240, y: 240, width: 760, height: 480)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OpenReaction picker preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewBackdrop())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        picker.model.onChoose = { [weak self] index in
            guard let self else { return }
            self.picker.moveSelection(by: index - self.picker.model.selectedIndex)
        }
        let caret = CGRect(x: frame.minX + 250, y: frame.minY + 300, width: 0, height: 20)
        picker.onVisibilityChange = { quartzFrame in
            if let quartzFrame {
                print("PREVIEW_PANEL_QUARTZ \(Int(quartzFrame.minX)) \(Int(quartzFrame.minY)) \(Int(quartzFrame.width)) \(Int(quartzFrame.height))")
            }
        }
        picker.present(provider.suggestions(for: "sm", usage: [:], limit: PickerMetrics.maxItems), caret: caret)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windowFrame = window.frame
        print("PREVIEW_WINDOW_QUARTZ \(Int(windowFrame.minX)) \(Int(primaryHeight - windowFrame.maxY)) \(Int(windowFrame.width)) \(Int(windowFrame.height))")

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch Int(event.keyCode) {
            case 123, 126: self?.picker.moveSelection(by: -1); return nil
            case 124, 125: self?.picker.moveSelection(by: 1); return nil
            default: return event
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [picker] in
            picker.moveSelection(by: 2)
        }
    }
}

private struct PreviewBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(nsColor: NSColor(hex: 0x304BFF)), Color(nsColor: NSColor(hex: 0xF3A0DC)), Color(nsColor: NSColor(hex: 0xFFD528))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle().fill(Color(nsColor: NSColor(hex: 0x91DCB4))).frame(width: 260).offset(x: 60, y: 200)
            Circle().fill(Color(nsColor: NSColor(hex: 0x141414))).frame(width: 140).offset(x: 280, y: 280)
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.9)).frame(width: 520, height: 44).offset(x: 110, y: 120)
            Text("Party time :sm")
                .font(.system(size: 17))
                .foregroundStyle(.black)
                .offset(x: 128, y: 131)
        }
    }
}
