import SwiftUI

/// A line chart of recent values. Auto-scales with headroom so an idle
/// machine still shows movement without amplifying noise to full height.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Brand.accentSolid
    /// nil = auto-scale with headroom (good for CPU); a value = fixed scale
    /// (good for memory, which is meaningfully 0-100).
    var fixedCeiling: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let ceiling = fixedCeiling ?? max((values.max() ?? 0) * 1.25, 10)
            if values.count > 1 {
                let points = values.enumerated().map { index, value in
                    CGPoint(x: w * CGFloat(index) / CGFloat(values.count - 1),
                            y: h * (1 - CGFloat(min(value / ceiling, 1))))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.14))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One thin bar per core, height = that core's load.
struct CoreBars: View {
    let perCore: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(perCore.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Level.load(value).color)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, 18 * value / 100))
            }
        }
        .frame(height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Two-segment ring: used in the state colour, the rest as a quiet track.
struct Ring: View {
    let fraction: Double
    let color: Color
    private let gap = 0.02

    var body: some View {
        ZStack {
            Circle()
                .stroke(Brand.hover, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Circle()
                .trim(from: gap, to: max(gap, min(1 - gap, fraction - gap)))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

/// A capacity bar: the filled part in the state colour on a quiet track.
struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.hover)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
