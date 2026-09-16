import AppKit
import MacPaperCore
import SwiftUI

/// The menu-bar item and its popover: the same content as the notch panel,
/// and the only surface when the panel is off or has no host.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let showSettings: () -> Void
    private let quit: () -> Void
    private let item: NSStatusItem
    private var popover: NSPopover?
    /// Closes any open notch panel before the popover shows.
    var beforeOpen: () -> Void = {}
    /// The licensing wiring's header (the trial pill); nil draws nothing.
    var header: (() -> AnyView)?

    init(model: AppModel, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.showSettings = showSettings
        self.quit = quit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = AppResources.menuBarImage()
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("macPaper")
            button.toolTip = "macPaper"
        }
    }

    var isShown: Bool { popover?.isShown ?? false }

    /// The item's frame in screen coordinates: where a display without a
    /// notch hangs the column.
    var buttonFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc func toggle() {
        if isShown {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard let button = item.button else { return }
        beforeOpen()
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.delegate = self
            // The column is dark in both appearances (PanelTheme).
            popover.appearance = NSAppearance(named: .darkAqua)
            let screen = button.window?.screen ?? NSScreen.main
            let height = PanelLayout.columnHeight(
                screenHeight: screen?.frame.height ?? 900,
                topInset: (screen.map(ScreenCatalog.menuBarHeight(of:)) ?? 24) + PanelLayout.popoverGap
            )
            popover.contentViewController = NSHostingController(rootView: PopoverContent(
                model: model, height: height, header: header?(), showSettings: showSettings, quit: quit, dismiss: { [weak self] in self?.close() }
            ))
            self.popover = popover
        }
        // The popover speaks for the display the menu bar item is on.
        if let screen = button.window?.screen, let id = ScreenCatalog.displayID(of: screen) {
            model.targetDisplay = id
        }
        model.clearStatus()
        popover?.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        // Freed so the next open reads the current settings and displays.
        popover = nil
    }
}

/// The same column as the notch panel, the regular width, as tall as the
/// screen allows; the popover's own frame is around it.
private struct PopoverContent: View {
    let model: AppModel
    let height: CGFloat
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        WallpaperPanelView(model: model, width: PanelMetrics.popoverWidth, height: height, header: header, showSettings: showSettings, quit: quit, dismiss: dismiss)
    }
}
