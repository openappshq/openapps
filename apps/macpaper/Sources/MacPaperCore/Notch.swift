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

    /// The panel's frame: centered on the notch (or the screen), its top
    /// against the menu bar's bottom, `contentHeight` tall, and kept inside
    /// the screen horizontally.
    public static func panelFrame(screenFrame: CGRect, menuBarHeight: CGFloat, notch: CGRect?, width: PanelWidth, contentHeight: CGFloat) -> CGRect {
        let centerX = notch?.midX ?? screenFrame.midX
        let width = min(width.points, screenFrame.width)
        var x = centerX - width / 2
        x = max(screenFrame.minX, min(x, screenFrame.maxX - width))
        let top = screenFrame.maxY - max(menuBarHeight, notch?.height ?? 0)
        let height = min(contentHeight, top - screenFrame.minY)
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
