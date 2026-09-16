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
            popover.contentViewController = NSHostingController(rootView: PopoverContent(model: model, showSettings: showSettings, quit: quit))
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

private struct PopoverContent: View {
    let model: AppModel
    let showSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        WallpaperPanelView(model: model, showSettings: showSettings, quit: quit)
    }
}
