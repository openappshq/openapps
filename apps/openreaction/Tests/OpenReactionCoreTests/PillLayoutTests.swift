import CoreGraphics
import OpenReactionCore
import Testing

@Suite("Pill layout")
struct PillLayoutTests {
    let layout = PillLayout(cell: 40, padding: 6, labelTrailing: 12, maxWidth: 300, peek: 20)

    @Test func selectedCellWidensForItsLabel() {
        #expect(layout.cellWidth(2, selected: 2, labelWidth: 50) == 102)
        #expect(layout.cellWidth(1, selected: 2, labelWidth: 50) == 40)
        #expect(layout.height == 52)
    }

    @Test func contentAndVisibleWidth() {
        // padding 12 + three cells 120 + label 50 and trailing 12
        #expect(layout.contentWidth(count: 3, labelWidth: 50) == CGFloat(194))
        #expect(layout.visibleWidth(count: 3, labelWidth: 50) == 194)
        #expect(layout.visibleWidth(count: 9, labelWidth: 80) == 300)
        #expect(layout.contentWidth(count: 0, labelWidth: 80) == 0)
    }

    @Test func stableWidthUsesLongestLabel() {
        #expect(layout.stableWidth(count: 3, labelWidths: [20, 60, 40]) == layout.visibleWidth(count: 3, labelWidth: 60))
    }

    @Test func cellsAfterSelectionShiftByLabel() {
        #expect(layout.cellMinX(0, selected: 1, labelWidth: 50) == 6)
        #expect(layout.cellMinX(1, selected: 1, labelWidth: 50) == 46)
        // after the widened selected cell: 46 + 102
        #expect(layout.cellMinX(2, selected: 1, labelWidth: 50) == CGFloat(148))
    }

    @Test func noScrollWhenEverythingFits() {
        #expect(layout.scrollOffset(selected: 2, count: 3, labelWidth: 50, current: 40) == 0)
    }

    @Test func scrollsToKeepSelectionAndPeekVisible() {
        // 9 cells, label 60: content = 12 + 360 + 72 = 444, visible 300, max offset 144.
        let offset = layout.scrollOffset(selected: 5, count: 9, labelWidth: 60, current: 0)
        let minX = layout.cellMinX(5, selected: 5, labelWidth: 60)
        let maxX = minX + layout.cellWidth(5, selected: 5, labelWidth: 60)
        #expect(maxX + 20 - offset <= 300)
        #expect(minX >= offset)
    }

    @Test func lastSelectionScrollsFullyToTheEnd() {
        #expect(layout.scrollOffset(selected: 8, count: 9, labelWidth: 60, current: 0) == 144)
    }

    @Test func movingBackRevealsPreviousCell() {
        let offset = layout.scrollOffset(selected: 1, count: 9, labelWidth: 60, current: 144)
        #expect(offset == layout.cellMinX(1, selected: 1, labelWidth: 60) - 20)
    }

    @Test func keepsCurrentOffsetWhenSelectionAlreadyVisible() {
        let offset = layout.scrollOffset(selected: 4, count: 9, labelWidth: 60, current: 60)
        #expect(offset == 60)
    }

    @Test func pillPlacementFlipsAndClamps() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: layout.stableWidth(count: 9, labelWidths: [60]), height: layout.height)
        let below = PanelPlacement.place(size: size, caret: CGRect(x: 700, y: 300, width: 0, height: 18), visibleFrames: [screen])
        #expect(!below.isAboveCaret)
        #expect(below.frame.maxX == 800)
        let above = PanelPlacement.place(size: size, caret: CGRect(x: 10, y: 20, width: 0, height: 18), visibleFrames: [screen])
        #expect(above.isAboveCaret)
        #expect(above.frame.minY == 42)
    }
}
