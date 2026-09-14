import CoreGraphics

/// Where the floating permission guide sits next to System Settings. AppKit
/// global coordinates throughout.
public enum GuidePlacement {
    /// Beside `window` on the screen that holds most of it: right side first,
    /// then left, otherwise inside the window's bottom-right corner. Without a
    /// window, vertically centered near the right edge of the first screen.
    public static func frame(
        size: CGSize,
        beside window: CGRect?,
        visibleFrames: [CGRect],
        gap: CGFloat = 12
    ) -> CGRect {
        guard let screen = visibleFrames.first else {
            return CGRect(origin: .zero, size: size)
        }
        guard let window, !window.isEmpty else {
            let origin = CGPoint(x: screen.maxX - size.width - gap * 2, y: screen.midY - size.height / 2)
            return clamp(CGRect(origin: origin, size: size), in: screen)
        }
        let host = visibleFrames.max { overlap($0, window) < overlap($1, window) } ?? screen
        let top = window.maxY - size.height - 64

        if window.maxX + gap + size.width <= host.maxX {
            return clamp(CGRect(x: window.maxX + gap, y: top, width: size.width, height: size.height), in: host)
        }
        if window.minX - gap - size.width >= host.minX {
            return clamp(CGRect(x: window.minX - gap - size.width, y: top, width: size.width, height: size.height), in: host)
        }
        let inside = CGRect(x: window.maxX - size.width - gap, y: window.minY + gap, width: size.width, height: size.height)
        return clamp(inside, in: host)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func clamp(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }
}
