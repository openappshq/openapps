import CoreGraphics
import Foundation

public enum PanelWidth: String, Codable, CaseIterable, Hashable, Sendable {
    case compact, regular, wide

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .wide: "Wide"
        }
    }

    /// Points.
    public var points: CGFloat {
        switch self {
        case .compact: 360
        case .regular: 440
        case .wide: 560
        }
    }
}

/// The column's frame under the menu-bar item, in the display's AppKit
/// coordinates (origin bottom-left). Pure geometry over what `NSScreen`
/// reports: the frame and the visible frame.
public enum PanelGeometry {
    /// The column's top edge: a margin under the menu bar (the visible
    /// frame's top).
    public static func top(visibleFrame: CGRect) -> CGFloat {
        visibleFrame.maxY - PanelLayout.edgeMargin
    }

    /// The column's frame on a display. `screenFrame` and `visibleFrame`
    /// are the screen's own (`NSScreen.frame` / `.visibleFrame`); the
    /// visible frame leaves out the menu bar and the Dock, and the column
    /// stays inside it with `PanelLayout.edgeMargin` on every side, never
    /// above the menu bar, never off an edge.
    ///
    /// The column is centered on the menu-bar item (`item`, the item's
    /// frame in screen coordinates) like every menu-bar app's window, the
    /// same on every display; an item near an edge gets the column slid
    /// inside the margin. Without an item on this screen (the item hidden
    /// by a crowded menu bar) the column takes the top center.
    ///
    /// The height is the content's, up to `PanelLayout.heightCap` for the
    /// visible frame and never below the visible frame's bottom margin. A
    /// column wider than the visible frame is narrowed to fit.
    public static func panelFrame(screenFrame: CGRect, visibleFrame: CGRect, item: CGRect?, width: CGFloat, contentHeight: CGFloat) -> CGRect {
        let margin = PanelLayout.edgeMargin
        let width = min(width, max(0, visibleFrame.width - 2 * margin))
        var x = (item?.midX ?? visibleFrame.midX) - width / 2
        x = max(visibleFrame.minX + margin, min(x, visibleFrame.maxX - margin - width))
        let top = min(top(visibleFrame: visibleFrame), screenFrame.maxY)
        let cap = min(PanelLayout.heightCap(visibleHeight: visibleFrame.height), max(0, top - (visibleFrame.minY + margin)))
        let height = min(max(0, contentHeight), cap)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

// MARK: - Fullscreen

/// Whether the display in front is in a fullscreen space, from the window
/// list (bounds need no permission; only names would): the frontmost app
/// owns a window at the normal layer that covers the whole screen.
public enum FullscreenHeuristic {
    public struct Window: Sendable {
        public let ownerPID: Int32
        public let layer: Int
        public let bounds: CGRect

        public init(ownerPID: Int32, layer: Int, bounds: CGRect) {
            self.ownerPID = ownerPID
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// `screenBounds` and the window bounds are in the same coordinate
    /// space (Quartz, as `CGWindowListCopyWindowInfo` reports them).
    public static func isFullscreen(windows: [Window], frontmostPID: Int32?, screenBounds: CGRect, tolerance: CGFloat = 1) -> Bool {
        guard let frontmostPID else { return false }
        return windows.contains { window in
            window.ownerPID == frontmostPID && window.layer == 0
                && abs(window.bounds.minX - screenBounds.minX) <= tolerance
                && abs(window.bounds.minY - screenBounds.minY) <= tolerance
                && abs(window.bounds.width - screenBounds.width) <= tolerance
                && abs(window.bounds.height - screenBounds.height) <= tolerance
        }
    }
}

// MARK: - The clock on the wallpaper layer

public enum ClockStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case off, analog, digital

    public var title: String {
        switch self {
        case .off: "Off"
        case .analog: "Analog"
        case .digital: "Digital"
        }
    }
}

public enum ClockPosition: String, Codable, CaseIterable, Hashable, Sendable {
    case topLeft, topRight, center, bottomLeft, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .center: "Center"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

public enum ClockSize: String, Codable, CaseIterable, Hashable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The face's edge in points.
    public var points: CGFloat {
        switch self {
        case .small: 160
        case .medium: 240
        case .large: 360
        }
    }
}

/// The clock's colors from the document it sits on: a face that reads over
/// the document's mean (light or dark) and hands in its most saturated
/// color, lightened or darkened to contrast with the face.
public struct ClockPalette: Hashable, Sendable {
    public let face: RGBAColor
    public let hands: RGBAColor
    public let ticks: RGBAColor

    public static func make(for wallpaper: Wallpaper?, side: Side) -> ClockPalette {
        let colors = wallpaper?.generator(for: side).colors ?? []
        let mean = colors.isEmpty ? 0.5 : colors.reduce(0) { $0 + $1.luminance } / Double(colors.count)
        let onDark = mean < 0.35
        let face = onDark ? RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.85) : RGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 0.85)
        var accent = OKLCH(colors.max { OKLCH($0).c < OKLCH($1).c } ?? RGBAColor(hex: 0xFF7A2F))
        if accent.c < 0.04 { accent.c = 0.12 }
        accent.l = onDark ? 0.78 : 0.42
        return ClockPalette(face: face, hands: accent.color, ticks: face)
    }

    /// The clock's frame on a display, in the display's AppKit coordinates,
    /// with a margin of one twelfth of the face.
    public static func frame(in screen: CGRect, position: ClockPosition, size: ClockSize, menuBarHeight: CGFloat) -> CGRect {
        let edge = size.points
        let margin = edge / 6
        let x: CGFloat, y: CGFloat
        switch position {
        case .topLeft: x = screen.minX + margin; y = screen.maxY - menuBarHeight - margin - edge
        case .topRight: x = screen.maxX - margin - edge; y = screen.maxY - menuBarHeight - margin - edge
        case .center: x = screen.midX - edge / 2; y = screen.midY - edge / 2
        case .bottomLeft: x = screen.minX + margin; y = screen.minY + margin
        case .bottomRight: x = screen.maxX - margin - edge; y = screen.minY + margin
        }
        return CGRect(x: x, y: y, width: edge, height: edge)
    }
}
