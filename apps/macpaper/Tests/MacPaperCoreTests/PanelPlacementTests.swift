import Foundation
@testable import MacPaperCore
import Testing

/// The panel's placement math (design/products/macpaper.md, "The panel"):
/// pure geometry over a display's `frame` and `visibleFrame`, run on a
/// notched 14" MacBook Pro, a 1440×900 and a 1280×800 display without one,
/// a secondary display with its own menu bar, and the left and right edges.
@Suite("Panel placement")
struct PanelPlacementTests {
    /// A 14" MacBook Pro: 1512×982, a 37-point menu bar, the notch centered.
    static let notchedScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let notchedVisible = CGRect(x: 0, y: 0, width: 1512, height: 945)
    static let notch = CGRect(x: 630, y: 945, width: 252, height: 37)

    @Test("The notch anchor centers the column on the notch, squared against it, capped by the display")
    func notchAnchor() {
        let short = NotchGeometry.panelFrame(screenFrame: Self.notchedScreen, visibleFrame: Self.notchedVisible, anchor: .notch(Self.notch), width: 440, contentHeight: 500)
        #expect(short.midX == 756 && short.maxY == 945 && short.height == 500)

        let capped = NotchGeometry.panelFrame(screenFrame: Self.notchedScreen, visibleFrame: Self.notchedVisible, anchor: .notch(Self.notch), width: 440, contentHeight: 5000)
        #expect(capped.height == 920, "the maximum, not however much room the visible frame has")

        // A 70-point Dock trims the visible frame's bottom, not its top.
        let withDock = CGRect(x: 0, y: 70, width: 1512, height: 875)
        let overDock = NotchGeometry.panelFrame(screenFrame: Self.notchedScreen, visibleFrame: withDock, anchor: .notch(Self.notch), width: 440, contentHeight: 5000)
        #expect(overDock.height == 859, "875 − 16")
        #expect(overDock.minY >= 78, "never off the bottom")
    }

    @Test("The menu-bar item anchor centers on the item, clamped to the notched display's right edge")
    func statusItemOnNotchedDisplay() {
        let item = CGRect(x: 1372, y: 952, width: 28, height: 22)
        let frame = NotchGeometry.panelFrame(screenFrame: Self.notchedScreen, visibleFrame: Self.notchedVisible, anchor: .statusItem(item), width: 440, contentHeight: 400)
        #expect(frame.maxX == CGFloat(1512 - 8))
        #expect(frame.maxY == CGFloat(945 - 8))
    }

    @Test("A display without a notch: the item anchor centers under it, an 8-point margin under the menu bar")
    func statusItemOnPlainDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let item = CGRect(x: 1300, y: 877, width: 28, height: 22)
        let frame = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .statusItem(item), width: 440, contentHeight: 700)
        #expect(frame.maxX == CGFloat(1440 - 8), "close enough to the right edge that a centered column would clip it")
        #expect(frame.maxY == 868)
        #expect(frame.height == 700)
        #expect(frame.minY == 168)
    }

    @Test("A small display: the column never grows past the visible frame, and never dips below its bottom margin")
    func smallDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 776)
        let item = CGRect(x: 600, y: 780, width: 28, height: 22)
        let frame = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .statusItem(item), width: 440, contentHeight: 2000)
        #expect(frame.height == CGFloat(800 - 24 - 16))
        #expect(frame.minY == 8)
        #expect(frame.maxY == 768)
    }

    @Test("A secondary display keeps its own menu bar and its own edges")
    func secondaryDisplay() {
        let screen = CGRect(x: 1512, y: 200, width: 1920, height: 1080)
        let visible = CGRect(x: 1512, y: 200, width: 1920, height: 1056)
        let centered = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .topCenter, width: 560, contentHeight: 900)
        #expect(centered.midX == 2472 && centered.maxY == 1256 - 8)

        let rightItem = CGRect(x: 3300, y: 1058, width: 28, height: 22)
        let right = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .statusItem(rightItem), width: 440, contentHeight: 900)
        #expect(right.maxX == CGFloat(3432 - 8))

        let leftItem = CGRect(x: 1512, y: 1058, width: 28, height: 22)
        let left = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .statusItem(leftItem), width: 440, contentHeight: 900)
        #expect(left.minX == 1520)
    }

    @Test("A column wider than the visible frame narrows to fit; a non-positive content height is zero")
    func widthAndEmptyContent() {
        let screen = CGRect(x: 0, y: 0, width: 600, height: 800)
        let visible = CGRect(x: 0, y: 0, width: 600, height: 776)
        let narrowed = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .topCenter, width: 1000, contentHeight: 300)
        #expect(narrowed.width == CGFloat(600 - 16))
        let empty = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .topCenter, width: 440, contentHeight: 0)
        #expect(empty.height == 0)
        let negative = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, anchor: .topCenter, width: 440, contentHeight: -50)
        #expect(negative.height == 0)
    }

    @Test("resolve: hover and click go to the notch or the top center, never the item; the item opener goes to the item; the hotkey prefers the notch when it may show")
    func resolve() {
        let notch = Self.notch
        let item = CGRect(x: 1380, y: 952, width: 28, height: 22)
        #expect(PanelAnchor.resolve(opener: .hover, notch: notch, item: item, notchPanelMayShow: true) == .notch(notch))
        #expect(PanelAnchor.resolve(opener: .click, notch: notch, item: item, notchPanelMayShow: true) == .notch(notch))
        #expect(PanelAnchor.resolve(opener: .hover, notch: nil, item: item, notchPanelMayShow: true) == .topCenter, "never the item")
        #expect(PanelAnchor.resolve(opener: .click, notch: nil, item: item, notchPanelMayShow: false) == .topCenter, "never the item")
        #expect(PanelAnchor.resolve(opener: .statusItem, notch: notch, item: item, notchPanelMayShow: true) == .statusItem(item))
        #expect(PanelAnchor.resolve(opener: .statusItem, notch: notch, item: nil, notchPanelMayShow: true) == .topCenter)
        #expect(PanelAnchor.resolve(opener: .hotkey, notch: notch, item: item, notchPanelMayShow: true) == .notch(notch))
        #expect(PanelAnchor.resolve(opener: .hotkey, notch: notch, item: item, notchPanelMayShow: false) == .statusItem(item), "the notch panel may not show")
        #expect(PanelAnchor.resolve(opener: .hotkey, notch: nil, item: item, notchPanelMayShow: true) == .statusItem(item), "no notch on this screen")
        #expect(PanelAnchor.resolve(opener: .hotkey, notch: nil, item: nil, notchPanelMayShow: true) == .topCenter)
    }

    @Test("The menu-bar shade is the strip above the column, only over a notch anchor")
    func menuBarShade() {
        let frame = NotchGeometry.panelFrame(screenFrame: Self.notchedScreen, visibleFrame: Self.notchedVisible, anchor: .notch(Self.notch), width: 440, contentHeight: 500)
        let shade = NotchGeometry.menuBarShadeFrame(screenFrame: Self.notchedScreen, anchor: .notch(Self.notch), panelFrame: frame)
        #expect(shade == CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: Self.notchedScreen.maxY - frame.maxY))
        let item = CGRect(x: 1372, y: 952, width: 28, height: 22)
        #expect(NotchGeometry.menuBarShadeFrame(screenFrame: Self.notchedScreen, anchor: .statusItem(item), panelFrame: frame) == nil)
        #expect(NotchGeometry.menuBarShadeFrame(screenFrame: Self.notchedScreen, anchor: .topCenter, panelFrame: frame) == nil)
    }

    @Test("The hint zone is the notch grown by hintReach and clipped to the screen; the glow hangs under it by hintDepth")
    func hintZoneAndGlow() {
        let zone = NotchGeometry.hintZone(screenFrame: Self.notchedScreen, notch: Self.notch)
        #expect(zone == Self.notch.insetBy(dx: -PanelLayout.hintReach, dy: -PanelLayout.hintReach).intersection(Self.notchedScreen))
        let glow = NotchGeometry.hintGlowFrame(screenFrame: Self.notchedScreen, notch: Self.notch)
        #expect(glow.width == zone.width)
        #expect(glow.height == PanelLayout.hintDepth)
        #expect(glow.minY == Self.notch.minY - PanelLayout.hintDepth)
        #expect(glow.minX == zone.minX)
    }
}
