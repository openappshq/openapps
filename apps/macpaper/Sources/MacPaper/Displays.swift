import AppKit
import MacPaperCore

/// What `NSScreen` says about the displays, in the core's terms.
enum ScreenCatalog {
    static func displayID(of screen: NSScreen) -> DisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for display: DisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == display }
    }

    /// The notch rect of a screen in its own AppKit coordinates, nil without one.
    static func notch(of screen: NSScreen) -> CGRect? {
        NotchGeometry.notchRect(
            screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }

    /// The menu bar's height on a screen: what the visible frame leaves at
    /// the top, or the notch's height on a notched screen (where the menu
    /// bar is as tall as the notch).
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let fromVisible = screen.frame.maxY - screen.visibleFrame.maxY
        return max(fromVisible, screen.safeAreaInsets.top, 22)
    }

    static func info(for screen: NSScreen) -> DisplayInfo? {
        guard let id = displayID(of: screen) else { return nil }
        return DisplayInfo(
            id: id, name: screen.localizedName, pointSize: screen.frame.size, scale: screen.backingScaleFactor,
            notchWidth: notch(of: screen)?.width, isMain: screen == NSScreen.screens.first
        )
    }

    /// Every display, the main one first (as `NSScreen.screens` orders them).
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap(info(for:))
    }
}

/// The real applier: `NSWorkspace.setDesktopImageURL` for the screen of the
/// display. Used by the running app only; the preview harness and the tests
/// never construct one.
struct WorkspaceDesktopApplier: DesktopApplier {
    struct NoSuchDisplay: Error, LocalizedError {
        let display: DisplayID
        var errorDescription: String? { "Display \(display) is not connected." }
    }

    /// Called from the render task, off the main actor: the screen lookup
    /// and the workspace call hop to the main thread and wait.
    func apply(imageAt url: URL, to display: DisplayID) throws {
        if Thread.isMainThread {
            try MainActor.assumeIsolated { try set(url, for: display) }
        } else {
            try DispatchQueue.main.sync { try MainActor.assumeIsolated { try set(url, for: display) } }
        }
    }

    /// What the display shows now, for the pin. Off the main thread this
    /// hops over and waits like `apply`.
    func currentImageURL(for display: DisplayID) -> URL? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { current(for: display) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { current(for: display) } }
    }

    @MainActor
    private func current(for display: DisplayID) -> URL? {
        guard let screen = ScreenCatalog.screen(for: display) else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    @MainActor
    private func set(_ url: URL, for display: DisplayID) throws {
        guard let screen = ScreenCatalog.screen(for: display) else { throw NoSuchDisplay(display: display) }
        // Scaling and the fill color are macOS's defaults: the image is
        // rendered at the display's pixel size, so nothing is scaled.
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }
}
