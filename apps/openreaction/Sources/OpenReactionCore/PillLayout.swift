import CoreGraphics

/// Geometry of the horizontal picker pill: a row of emoji cells where the
/// selected cell widens to show its `:shortcode:` label.
public struct PillLayout: Equatable, Sendable {
    /// Width and height of one emoji cell.
    public var cell: CGFloat
    /// Inset between the pill edge and the first/last cell.
    public var padding: CGFloat
    /// Space after the label inside the selected cell.
    public var labelTrailing: CGFloat
    /// Widest the pill may get; wider content scrolls.
    public var maxWidth: CGFloat
    /// How much of the next cell stays visible at a clipped trailing edge.
    public var peek: CGFloat

    public init(cell: CGFloat = 40, padding: CGFloat = 6, labelTrailing: CGFloat = 12, maxWidth: CGFloat = 420, peek: CGFloat = 20) {
        self.cell = cell
        self.padding = padding
        self.labelTrailing = labelTrailing
        self.maxWidth = maxWidth
        self.peek = peek
    }

    public var height: CGFloat { cell + padding * 2 }

    /// Width of cell `index` when `selected` shows a label of `labelWidth`.
    public func cellWidth(_ index: Int, selected: Int, labelWidth: CGFloat) -> CGFloat {
        index == selected ? cell + labelWidth + labelTrailing : cell
    }

    /// Unclipped width of the whole row including padding.
    public func contentWidth(count: Int, labelWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return padding * 2 + CGFloat(count) * cell + labelWidth + labelTrailing
    }

    /// Visible pill width for a given selection.
    public func visibleWidth(count: Int, labelWidth: CGFloat) -> CGFloat {
        min(contentWidth(count: count, labelWidth: labelWidth), maxWidth)
    }

    /// Window-size width that fits every possible selection, so the panel does
    /// not move when the selection changes.
    public func stableWidth(count: Int, labelWidths: [CGFloat]) -> CGFloat {
        visibleWidth(count: count, labelWidth: labelWidths.max() ?? 0)
    }

    /// Leading x of cell `index` within the unclipped row.
    public func cellMinX(_ index: Int, selected: Int, labelWidth: CGFloat) -> CGFloat {
        var x = padding + CGFloat(index) * cell
        if index > selected { x += labelWidth + labelTrailing }
        return x
    }

    /// Horizontal scroll offset that keeps the selected cell fully visible,
    /// with the following cell peeking in when there is one. Moves as little
    /// as possible from `current`.
    public func scrollOffset(selected: Int, count: Int, labelWidth: CGFloat, current: CGFloat) -> CGFloat {
        let content = contentWidth(count: count, labelWidth: labelWidth)
        let visible = min(content, maxWidth)
        let maxOffset = max(0, content - visible)
        guard maxOffset > 0, count > 0 else { return 0 }

        let minX = cellMinX(selected, selected: selected, labelWidth: labelWidth)
        let maxX = minX + cellWidth(selected, selected: selected, labelWidth: labelWidth)
        let trailingNeed = selected < count - 1 ? maxX + peek : maxX + padding
        let leadingNeed = selected > 0 ? minX - peek : 0

        var offset = min(max(current, 0), maxOffset)
        if trailingNeed - offset > visible { offset = trailingNeed - visible }
        if leadingNeed < offset { offset = leadingNeed }
        return min(max(offset, 0), maxOffset)
    }
}
