import CoreGraphics
import Foundation

/// The notch panel's settings, as the user set them (Preferences) and as
/// the state machine and the geometry read them.
public enum HostDisplay: String, Codable, CaseIterable, Hashable, Sendable {
    /// The first display with a notch; without one, the popover only.
    case notchDisplay
    /// The display with the menu bar, notch or not.
    case mainDisplay
    /// One panel per notched display.
    case everyNotchedDisplay

    public var title: String {
        switch self {
        case .notchDisplay: "The notch display"
        case .mainDisplay: "The main display"
        case .everyNotchedDisplay: "Every notched display"
        }
    }

    /// Which displays host a panel.
    public func hosts(among displays: [DisplayInfo]) -> [DisplayInfo] {
        switch self {
        case .notchDisplay:
            displays.first(where: \.hasNotch).map { [$0] } ?? []
        case .mainDisplay:
            displays.first(where: \.isMain).map { [$0] } ?? Array(displays.prefix(1))
        case .everyNotchedDisplay:
            displays.filter(\.hasNotch)
        }
    }
}

public enum PanelTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case hover, click, both

    public var title: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        case .both: "Hover or click"
        }
    }

    public var opensOnHover: Bool { self != .click }
    public var opensOnClick: Bool { self != .hover }
}

/// Where the panel opens from the notch. v1 renders `down` only; the others
/// are stored so a setting survives until a release draws them.
public enum PanelDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case down, left, right

    public var title: String {
        switch self {
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        }
    }

    public var isRendered: Bool { self == .down }
}

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

/// The notch's place on a screen and the panel's frame under it, in the
/// screen's AppKit coordinates (origin bottom-left). Pure geometry from what
/// `NSScreen` reports: the frame, `safeAreaInsets.top` and the two
/// auxiliary top areas beside the notch.
public enum NotchGeometry {
    /// The notch rect: between the auxiliary areas, as tall as the top
    /// inset. Nil when the screen has no notch (no auxiliary areas).
    public static func notchRect(screenFrame: CGRect, topInset: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) -> CGRect? {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight, topInset > 0, right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: screenFrame.maxY - topInset, width: right.minX - left.maxX, height: topInset)
    }

    /// The strip the pointer must reach to open the panel by hover: the
    /// notch itself, or on a screen without one a 2-point hot edge, 200
    /// points wide, at the top center, so nothing in the menu bar is covered.
    public static func hoverZone(screenFrame: CGRect, notch: CGRect?) -> CGRect {
        if let notch { return notch }
        return CGRect(x: screenFrame.midX - 100, y: screenFrame.maxY - 2, width: 200, height: 2)
    }

    /// The zone around the notch in which the first-run glow shows: the
    /// notch grown by `PanelLayout.hintReach` on every side, clipped to
    /// the screen.
    public static func hintZone(screenFrame: CGRect, notch: CGRect) -> CGRect {
        notch.insetBy(dx: -PanelLayout.hintReach, dy: -PanelLayout.hintReach).intersection(screenFrame)
    }

    /// The glow's own frame: a strip as wide as the hint zone, hanging
    /// under the notch (the menu bar's bottom) by `PanelLayout.hintDepth`.
    public static func hintGlowFrame(screenFrame: CGRect, notch: CGRect) -> CGRect {
        let zone = hintZone(screenFrame: screenFrame, notch: notch)
        return CGRect(x: zone.minX, y: notch.minY - PanelLayout.hintDepth, width: zone.width, height: PanelLayout.hintDepth)
    }

    /// The column's top edge for an anchor: against the notch, or a margin
    /// under the menu bar (the visible frame's top) everywhere else.
    public static func top(of anchor: PanelAnchor, visibleFrame: CGRect) -> CGFloat {
        switch anchor {
        case .notch(let notch): notch.minY
        case .statusItem, .topCenter: visibleFrame.maxY - PanelLayout.edgeMargin
        }
    }

    /// The column's frame on a display. `screenFrame` and `visibleFrame`
    /// are the screen's own (`NSScreen.frame` / `.visibleFrame`, AppKit
    /// coordinates); the visible frame leaves out the menu bar and the
    /// Dock, and the column stays inside it with `PanelLayout.edgeMargin`
    /// on every side, never above the menu bar, never off an edge.
    ///
    /// - Notch: centered on the notch, its top squared against it.
    /// - Menu-bar item: centered on the item, a margin under the menu bar,
    ///   like every menu-bar app's window; the same on every display,
    ///   notch or not.
    /// - Top center: no notch and no item on this screen (the hotkey, the
    ///   hot edge of a display without a notch).
    ///
    /// The height is the content's, up to `PanelLayout.heightCap` for the
    /// visible frame and never below the visible frame's bottom margin. A
    /// column wider than the visible frame is narrowed to fit.
    public static func panelFrame(screenFrame: CGRect, visibleFrame: CGRect, anchor: PanelAnchor, width: CGFloat, contentHeight: CGFloat) -> CGRect {
        let margin = PanelLayout.edgeMargin
        let width = min(width, max(0, visibleFrame.width - 2 * margin))
        var x: CGFloat
        switch anchor {
        case .notch(let notch): x = notch.midX - width / 2
        case .statusItem(let item): x = item.midX - width / 2
        case .topCenter: x = visibleFrame.midX - width / 2
        }
        x = max(visibleFrame.minX + margin, min(x, visibleFrame.maxX - margin - width))
        let top = min(top(of: anchor, visibleFrame: visibleFrame), screenFrame.maxY)
        let cap = min(PanelLayout.heightCap(visibleHeight: visibleFrame.height), max(0, top - (visibleFrame.minY + margin)))
        let height = min(max(0, contentHeight), cap)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The strip the column shades above itself: the menu-bar row over a
    /// notch-anchored column, the column's width; nil for the other anchors
    /// (nothing sits over the menu bar there).
    public static func menuBarShadeFrame(screenFrame: CGRect, anchor: PanelAnchor, panelFrame: CGRect) -> CGRect? {
        guard case .notch = anchor else { return nil }
        let height = screenFrame.maxY - panelFrame.maxY
        guard height > 0 else { return nil }
        return CGRect(x: panelFrame.minX, y: panelFrame.maxY, width: panelFrame.width, height: height)
    }
}

/// What the column hangs from.
public enum PanelAnchor: Equatable, Sendable {
    /// The notch rect on that screen: the column is centered on the notch,
    /// squared against it, and shades the menu bar row.
    case notch(CGRect)
    /// The menu-bar item's frame in screen coordinates: the column opens
    /// under it, centered on it, rounded all round — on any display.
    case statusItem(CGRect)
    /// No notch and no item on this screen: the top center.
    case topCenter

    public var isNotch: Bool {
        if case .notch = self { return true }
        return false
    }

    /// The anchor an opener gets on a screen: the hover zone's own place
    /// (the notch, or the top center of a display without one) for a hover
    /// or a click on it; the menu-bar item for a click on it; the hotkey
    /// the notch where the notch panel may show, else the item, else the
    /// top center. `item` is the menu-bar item's frame when it sits on
    /// this screen.
    public static func resolve(opener: PanelOpener, notch: CGRect?, item: CGRect?, notchPanelMayShow: Bool) -> PanelAnchor {
        switch opener {
        case .hover, .click:
            return notch.map { .notch($0) } ?? .topCenter
        case .statusItem:
            return item.map { .statusItem($0) } ?? .topCenter
        case .hotkey:
            if notchPanelMayShow, let notch { return .notch(notch) }
            return item.map { .statusItem($0) } ?? .topCenter
        }
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
