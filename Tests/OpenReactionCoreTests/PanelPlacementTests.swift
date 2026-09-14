import CoreGraphics
import OpenReactionCore
import Testing

@Suite("Panel placement")
struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 280, height: 240)

    @Test func placesBelowCaretByDefault() {
        let caret = CGRect(x: 100, y: 600, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [screen], gap: 4)
        #expect(!result.isAboveCaret)
        #expect(result.frame == CGRect(x: 100, y: 600 - 4 - 240, width: 280, height: 240))
    }

    @Test func flipsAboveNearScreenBottom() {
        let caret = CGRect(x: 100, y: 60, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [screen], gap: 4)
        #expect(result.isAboveCaret)
        #expect(result.frame == CGRect(x: 100, y: 82, width: 280, height: 240))
    }

    @Test func picksRoomierSideAndClampsWhenNeitherFits() {
        let short = CGRect(x: 0, y: 0, width: 800, height: 300)
        let caret = CGRect(x: 10, y: 200, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [short], gap: 4)
        #expect(!result.isAboveCaret)
        #expect(result.frame.minY == 0)
        #expect(short.contains(result.frame))
    }

    @Test func clampsHorizontallyAtRightEdge() {
        let caret = CGRect(x: 1400, y: 600, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [screen])
        #expect(result.frame.maxX == screen.maxX)
    }

    @Test func leadingOffsetAlignsContentWithCaret() {
        let caret = CGRect(x: 300, y: 600, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [screen], leadingOffset: 12)
        #expect(result.frame.minX == 288)
    }

    @Test func usesScreenContainingCaretOnMultipleDisplays() {
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let caret = CGRect(x: 1500, y: -150, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [screen, secondary])
        #expect(result.isAboveCaret)
        #expect(secondary.contains(result.frame))
    }

    @Test func caretOffAllScreensUsesNearestScreen() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let caret = CGRect(x: 5000, y: 500, width: 1, height: 18)
        let result = PanelPlacement.place(size: size, caret: caret, visibleFrames: [screen, secondary])
        #expect(secondary.contains(result.frame))
        #expect(result.frame.maxX == secondary.maxX)
    }

    @Test func convertsQuartzToAppKitCoordinates() {
        let quartz = CGRect(x: 50, y: 100, width: 2, height: 20)
        #expect(PanelPlacement.appKitRect(fromQuartz: quartz, primaryScreenHeight: 900) == CGRect(x: 50, y: 780, width: 2, height: 20))
    }

    @Test func rejectsImplausibleCaretRects() {
        #expect(!PanelPlacement.isPlausibleCaretRect(.zero))
        #expect(!PanelPlacement.isPlausibleCaretRect(.null))
        #expect(!PanelPlacement.isPlausibleCaretRect(CGRect(x: 10, y: 10, width: 400, height: 900)))
        #expect(!PanelPlacement.isPlausibleCaretRect(CGRect(x: 10, y: 10, width: 0, height: 0)))
        #expect(PanelPlacement.isPlausibleCaretRect(CGRect(x: 10, y: 10, width: 0, height: 17)))
    }
}
