import CoreGraphics
import Foundation

/// WCAG 2.x contrast between two opaque colors.
public enum Contrast {
    /// Normal text.
    public static let aaText = 4.5
    /// Large text, controls and focus rings.
    public static let aaLarge = 3.0

    public static func ratio(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `color` drawn at its alpha over an opaque `backdrop`.
    public static func composite(_ color: RGBAColor, over backdrop: RGBAColor) -> RGBAColor {
        backdrop.mixed(with: RGBAColor(red: color.red, green: color.green, blue: color.blue), amount: color.alpha)
    }
}

/// The notch panel's colors. The column hangs from the notch, so it is a
/// piece of the same black in both appearances: the dark tokens of
/// design/tokens.json (neutral/950 ground, neutral/850 surface, neutral/0
/// and neutral/400 text, the tangerine/300 accent with neutral/950 on it),
/// opaque, so what the wallpaper shows never reaches a label. Every text
/// pair here passes AA; `PanelThemeTests` asserts it against the four
/// backdrops the preview harness draws.
public enum PanelTheme {
    public static let ground = RGBAColor(hex: 0x141414)
    public static let surface = RGBAColor(hex: 0x202020)
    public static let hover = RGBAColor(hex: 0x2C2C2C)
    public static let textPrimary = RGBAColor(hex: 0xF8F8F8)
    public static let textSecondary = RGBAColor(hex: 0xBABABA)
    public static let border = RGBAColor(hex: 0x484848)
    /// A slider's inactive track: neutral/500, a control at 3:1 on the ground.
    public static let track = RGBAColor(hex: 0x858585)
    public static let accent = RGBAColor(hex: 0xFFB48A)
    public static let accentOn = RGBAColor(hex: 0x141414)
    public static let accentText = RGBAColor(hex: 0xFFCDB3)
    public static let danger = RGBAColor(hex: 0xFFACB8)
    public static let success = RGBAColor(hex: 0x91DCB4)
    /// The rim: neutral/700 at this alpha over the ground.
    public static let rimAlpha = 0.7
    /// The ground is opaque: a backdrop composited under it is the ground.
    public static let groundAlpha = 1.0
    /// The menu-bar row above a notch-anchored column is shaded this much.
    public static let menuBarShadeAlpha = 0.42

    /// The pairs the panel draws text and controls with, each with the
    /// ratio it must reach.
    public struct Pair: Sendable {
        public let name: String
        public let foreground: RGBAColor
        public let background: RGBAColor
        public let minimum: Double
    }

    public static let pairs: [Pair] = [
        Pair(name: "label on the ground", foreground: textPrimary, background: ground, minimum: Contrast.aaText),
        Pair(name: "secondary label on the ground", foreground: textSecondary, background: ground, minimum: Contrast.aaText),
        Pair(name: "label on a row surface", foreground: textPrimary, background: surface, minimum: Contrast.aaText),
        Pair(name: "secondary label on a row surface", foreground: textSecondary, background: surface, minimum: Contrast.aaText),
        Pair(name: "label on hover", foreground: textPrimary, background: hover, minimum: Contrast.aaText),
        Pair(name: "accent text on the ground", foreground: accentText, background: ground, minimum: Contrast.aaText),
        Pair(name: "text on the accent", foreground: accentOn, background: accent, minimum: Contrast.aaText),
        Pair(name: "the accent as a control on the ground", foreground: accent, background: ground, minimum: Contrast.aaLarge),
        Pair(name: "the accent as a control on a row surface", foreground: accent, background: surface, minimum: Contrast.aaLarge),
        Pair(name: "the inactive slider track on the ground", foreground: track, background: ground, minimum: Contrast.aaLarge),
        Pair(name: "danger on the ground", foreground: danger, background: ground, minimum: Contrast.aaText),
        Pair(name: "success on the ground", foreground: success, background: ground, minimum: Contrast.aaText),
    ]

    /// The ground as it lands over a wallpaper: with `groundAlpha` 1, the
    /// ground itself, whatever the wallpaper.
    public static func ground(over backdrop: RGBAColor) -> RGBAColor {
        Contrast.composite(RGBAColor(red: ground.red, green: ground.green, blue: ground.blue, alpha: groundAlpha), over: backdrop)
    }
}

/// The column's geometry, shared by the views, the window and the tests:
/// the rail, the pane's inset, the row rhythm, and the width a segmented
/// control needs so no label wraps.
public enum PanelLayout {
    /// The icon rail on the column's left.
    public static let railWidth: CGFloat = 56
    /// The pane's padding on every side.
    public static let paneInset: CGFloat = 20
    /// One parameter row: a label line and a slider, with its gap.
    public static let rowHeight: CGFloat = 72
    /// A row in a list (a recipe, a generator).
    public static let listRowHeight: CGFloat = 72
    /// Thumbnails in lists.
    public static let thumbnail: CGFloat = 56
    /// The header row with the section title and the reach control.
    public static let headerHeight: CGFloat = 44
    /// Segments: text padding each side, the gap between segments, the
    /// track's inset around them.
    public static let segmentPadding: CGFloat = 10
    public static let segmentSpacing: CGFloat = 2
    public static let segmentInset: CGFloat = 2
    /// The margin the column keeps inside the display's visible frame:
    /// under the menu bar (where it is not on the notch), at the bottom,
    /// and at the left and right edges.
    public static let edgeMargin: CGFloat = 8
    /// The column is never taller than this, whatever the display.
    public static let maximumHeight: CGFloat = 920
    /// How close the pointer comes to the notch, in points on every side,
    /// before the first-run glow shows.
    public static let hintReach: CGFloat = 80
    /// How far under the notch the glow reaches.
    public static let hintDepth: CGFloat = 40

    /// The width a segmented control takes so that its widest label fits on
    /// one line in every segment: every segment as wide as the widest
    /// label, plus the padding, the gaps and the track's inset.
    public static func segmentedWidth(labelWidths: [CGFloat], padding: CGFloat = segmentPadding, spacing: CGFloat = segmentSpacing, inset: CGFloat = segmentInset) -> CGFloat {
        guard let widest = labelWidths.max(), !labelWidths.isEmpty else { return 0 }
        let segment = ceil(widest) + 2 * padding
        return CGFloat(labelWidths.count) * segment + CGFloat(labelWidths.count - 1) * spacing + 2 * inset
    }

    /// What the pane leaves for a control at a column width.
    public static func paneWidth(columnWidth: CGFloat) -> CGFloat {
        columnWidth - railWidth - 2 * paneInset
    }

    /// The column's width: the setting's, unless a control needs more to
    /// keep its labels on one line.
    public static func columnWidth(setting: PanelWidth, controlWidths: [CGFloat]) -> CGFloat {
        let needed = (controlWidths.max() ?? 0) + railWidth + 2 * paneInset
        return max(setting.points, ceil(needed))
    }

    /// The tallest the column may be on a display: the visible frame's
    /// height less the margin above and below, at most `maximumHeight`.
    public static func heightCap(visibleHeight: CGFloat) -> CGFloat {
        min(maximumHeight, max(0, visibleHeight - 2 * edgeMargin))
    }

    /// The column's height on a display: the content's, up to the cap. The
    /// sections column scrolls inside a capped column; the rail and the
    /// footer stay put.
    public static func columnHeight(contentHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        min(max(0, contentHeight), heightCap(visibleHeight: visibleHeight))
    }
}
