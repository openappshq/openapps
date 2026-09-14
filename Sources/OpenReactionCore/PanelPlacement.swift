import CoreGraphics

/// Screen geometry for the picker. All rects use AppKit's global coordinate
/// space (origin at the bottom-left of the primary display, y grows upward)
/// unless a function says otherwise.
public enum PanelPlacement {
    public struct Result: Equatable, Sendable {
        public let frame: CGRect
        /// The panel sits above the caret because there was no room below.
        public let isAboveCaret: Bool
    }

    /// Places a panel of `size` next to `caret`.
    ///
    /// Prefers below the caret, aligned with its leading edge. Flips above when
    /// the screen's visible frame has no room below, picks the roomier side when
    /// neither fits, and always clamps inside the visible frame of the screen
    /// that contains the caret.
    public static func place(
        size: CGSize,
        caret: CGRect,
        visibleFrames: [CGRect],
        gap: CGFloat = 4,
        leadingOffset: CGFloat = 0
    ) -> Result {
        let screen = screenFrame(containing: caret, in: visibleFrames)
        let spaceBelow = caret.minY - gap - screen.minY
        let spaceAbove = screen.maxY - (caret.maxY + gap)

        let above: Bool
        if spaceBelow >= size.height {
            above = false
        } else if spaceAbove >= size.height {
            above = true
        } else {
            above = spaceAbove > spaceBelow
        }

        var origin = CGPoint(
            x: caret.minX - leadingOffset,
            y: above ? caret.maxY + gap : caret.minY - gap - size.height
        )
        origin.x = clamp(origin.x, lower: screen.minX, upper: screen.maxX - size.width)
        origin.y = clamp(origin.y, lower: screen.minY, upper: screen.maxY - size.height)
        return Result(frame: CGRect(origin: origin, size: size), isAboveCaret: above)
    }

    /// The visible frame containing the caret's center, else the one closest to it.
    public static func screenFrame(containing caret: CGRect, in visibleFrames: [CGRect]) -> CGRect {
        guard !visibleFrames.isEmpty else { return .infinite }
        let point = CGPoint(x: caret.midX, y: caret.midY)
        if let hit = visibleFrames.first(where: { $0.contains(point) }) {
            return hit
        }
        return visibleFrames.min { distanceSquared(point, $0) < distanceSquared(point, $1) }!
    }

    /// Converts a rect from Quartz/Accessibility global coordinates (origin at
    /// the top-left of the primary display, y grows downward) to AppKit's.
    public static func appKitRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Accessibility bounds that are safe to anchor to. Apps that do not
    /// implement text bounds often return zero rects or the whole text area.
    public static func isPlausibleCaretRect(_ rect: CGRect, maxHeight: CGFloat = 200) -> Bool {
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite else { return false }
        if rect.origin == .zero && rect.size == .zero { return false }
        return rect.height > 0 && rect.height <= maxHeight && rect.width >= 0
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        upper < lower ? lower : min(max(value, lower), upper)
    }

    private static func distanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
