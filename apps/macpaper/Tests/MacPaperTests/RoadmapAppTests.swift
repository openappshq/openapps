import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

/// The model's roadmap behaviors over the same fakes as AppModelTests.
@MainActor
struct RoadmapAppTests {
    @Test("A light/dark document applies as a HEIC pair and a refusing display gets the fallback still, swapped on theme change")
    func pairAndSwap() async throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        h.model.setPair(.lightDark)
        h.model.apply()
        await h.settle()
        #expect(h.desktop.calls.count == 2 && h.desktop.calls.allSatisfy { $0.url.pathExtension == "heic" })
        #expect(h.model.appliedState.fallbackDisplayIDs.isEmpty)
        h.desktop.refusesHEIC = true
        h.model.load(h.model.draft.reseeded(2))
        h.model.apply()
        await h.settle()
        #expect(h.model.appliedState.fallbackDisplayIDs == [1, 2])
        #expect(h.model.status?.text.contains("took a still instead of the pair") == true)
        let before = h.desktop.calls.count
        h.model.systemAppearance = { .dark }
        h.model.themeChanged()
        await h.settle()
        #expect(h.desktop.calls.count == before + 2, "both fallback displays swapped")
        #expect(h.desktop.calls.suffix(2).allSatisfy { $0.url.pathExtension == "png" })
        #expect(h.model.appliedState.fallbackDisplayIDs == [1, 2])
    }

    @Test("This Space only takes the display off the pin; every Space puts it back")
    func spaces() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = false
        h.model.targetDisplay = 1
        h.model.apply(ApplyTarget(thisSpaceOnly: true))
        await h.settle()
        #expect(h.model.appliedState.perSpaceDisplayIDs == [1])
        #expect(h.model.status?.text == "Applied to this Space.")
        h.model.apply()
        await h.settle()
        #expect(h.model.appliedState.perSpaceDisplayIDs.isEmpty)
        #expect(h.model.appliedState.file(for: 1) == h.desktop.calls.last?.url)
    }

    @Test("The keeper re-applies the recorded file where the display shows something else, and skips per-Space displays")
    func keeper() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.sameOnAllDisplays = true
        h.model.apply()
        await h.settle()
        let recorded = h.desktop.calls.map(\.url)
        let keeper = DesktopKeeper(model: h.model, preferences: h.preferences, desktop: h.desktop)
        // macOS "changed" display 2's wallpaper.
        h.desktop.currentOverride[2] = URL(fileURLWithPath: "/System/Library/Desktop Pictures/x.heic")
        keeper.check(reason: "test")
        try? await Task.sleep(for: .milliseconds(1000))
        #expect(h.desktop.calls.count == 3 && h.desktop.calls.last?.url == recorded[1] && h.desktop.calls.last?.display == 2)
        #expect(keeper.lastReport.contains("re-applied 2"))
        // Off: nothing.
        h.preferences.keepApplied = false
        h.desktop.currentOverride[1] = URL(fileURLWithPath: "/other.png")
        keeper.check(reason: "test")
        try? await Task.sleep(for: .milliseconds(900))
        #expect(h.desktop.calls.count == 3 && keeper.lastReport == "off")
    }

    @Test("Share links round-trip through the deep-link dispatcher; remix and never-show")
    func sharing() throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        var copied = ""
        h.model.copyToPasteboard = { copied = $0 }
        h.model.edit { $0.composition = .contours }
        h.model.shareLink()
        #expect(copied.hasPrefix("macpaper://s/"))
        let shared = h.model.draft
        h.model.load(.trueBlack)
        h.model.open(sharedLink: try #require(URL(string: copied)))
        #expect(h.model.draft == shared)
        h.model.open(sharedLink: URL(string: "macpaper://s/notacode")!)
        #expect(h.model.status?.tone == .error && h.model.draft == shared)
        h.model.remix()
        #expect(h.model.draft.seed != shared.seed && h.model.draft.composition == .contours)
        let blocked = h.model.draft
        try h.model.favorites.add(blocked)
        h.model.neverShowThis()
        #expect(h.model.blockedCount == 1 && h.model.blocklist.contains(blocked) && !h.model.favorites.contains(blocked))
        #expect(h.model.draft != blocked, "moved on to a new seed")
        h.model.clearBlocklist()
        #expect(h.model.blockedCount == 0)
    }

    @Test("Shuffle never picks a never-showed favorite")
    func shuffleAvoidsBlocked() async throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.preferences.favoritesOnly = true
        h.preferences.sameOnAllDisplays = true
        let a = Wallpaper.starter, b = Wallpaper.starter.reseeded(2)
        try h.model.favorites.add(a)
        try h.model.favorites.add(b)
        try h.model.blocklist.add(a)
        for _ in 0..<5 {
            h.model.shuffle()
            await h.settle()
            #expect(h.model.draft == b)
        }
    }

    @Test("Editing the dark side materialises it; true black clears the finishes; palettes and the focal point; nothing edits while restricted")
    func editing() {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.license.bind(access: { false }, restriction: { .trialEndedSample }, canBuy: true)
        let frozen = h.model.draft
        h.model.edit { $0.grain = 0.9 }
        h.model.reseed()
        h.model.setPair(.lightDark)
        h.model.binding(\.composition).wrappedValue = .pill
        h.model.editedGenerator = .solid(SolidParameters(color: .black))
        #expect(h.model.draft == frozen, "every edit asks the license and is dropped")
        h.license.bind(access: { true }, restriction: { nil }, canBuy: false)
        h.model.editingSide = .dark
        #expect(!h.model.draft.hasCustomDark)
        h.model.editedGenerator = .solid(SolidParameters(color: .black))
        #expect(h.model.draft.darkGenerator == .solid(SolidParameters(color: .black)) && h.model.draft.generator.kind == .gradient)
        h.model.resetDarkSide()
        #expect(!h.model.draft.hasCustomDark)
        h.model.editingSide = .light
        h.model.edit { $0.grain = 0.3; $0.finish.tint = Tint(color: .white, amount: 0.2) }
        h.model.useTrueBlack()
        #expect(h.model.draft.isTrueBlack)
        h.model.useAccentPalette()
        #expect(h.model.draft.generator.colors.first?.hexString == OKLCH(l: 0.16, c: OKLCH(RGBAColor(hex: 0x304BFF)).c * 0.5, h: OKLCH(RGBAColor(hex: 0x304BFF)).h).color.hexString)
        h.model.generatorKind = .gradient
        h.model.applyPalette([RGBAColor(hex: 0x111111), RGBAColor(hex: 0x222222), RGBAColor(hex: 0x333333)])
        #expect(h.model.draft.generator.colors.count == 3)
        h.model.shadeTheTop()
        #expect(h.model.draft.finish.topShade == 0.7)
        h.model.generatorKind = .pixelize
        #expect(!h.model.framesImage, "no source yet")
        if case .pixelize(var p) = h.model.draft.generator {
            p.source = ImageReference(fileName: "0123456789abcdef.png", contentHash: String(repeating: "0", count: 64))
            h.model.editedGenerator = .pixelize(p)
        }
        #expect(h.model.framesImage && h.model.isSourceMissing)
        h.model.setFocus(Point(x: 1.4, y: -1))
        #expect(h.model.focus == Point(x: 1, y: 0))
        h.model.generatorKind = .dither
        #expect(h.model.editedGenerator.source != nil, "the source carries over to dither")
    }

    @Test("Exports: HEIC pair and phone pair write their files")
    func exports() async throws {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.model.export(.heicPair)
        await h.settle()
        #expect(h.exporter.exported.last?.0.hasSuffix("-pair.heic") == true)
        let heic = try #require(h.exporter.exported.last?.1)
        #expect(DynamicDesktop.frameCount(in: heic) == 2)
        h.model.export(.phonePair)
        await h.settle()
        let names = h.exporter.exported.suffix(2).map(\.0)
        #expect(names[0].hasSuffix(".png") && names[1].hasSuffix("-phone.png"))
        let phoneData = try #require(h.exporter.exported.last?.1)
        let phone = try #require(Raster.decode(phoneData))
        #expect(phone.size == PhoneCanvas.size)
    }

    @Test("The preview follows the Mac's appearance until a side is picked, and reports readability")
    func previewSide() async {
        let h = AppModelTests.Harness()
        defer { h.tearDown() }
        h.model.systemAppearance = { .dark }
        h.model.editingSide = nil
        for _ in 0..<200 where h.model.previewSide != .dark || h.model.previewWallpaper != h.model.draft { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(h.model.previewSide == .dark && h.model.readability != nil)
        h.model.editingSide = .light
        for _ in 0..<200 where h.model.previewSide != .light { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(h.model.previewSide == .light && h.model.shownSide == .light)
    }

    @Test("The clock palette follows the wallpaper and its frame the position")
    func clock() {
        let dark = ClockPalette.make(for: .trueBlack, side: .dark)
        #expect(dark.face.red > 0.9, "a light face on a dark wallpaper")
        let light = ClockPalette.make(for: Wallpaper(generator: .solid(SolidParameters(color: .white)), seed: 1), side: .light)
        #expect(light.face.red < 0.2)
        let frame = ClockPalette.frame(in: CGRect(x: 0, y: 0, width: 1512, height: 982), position: .bottomRight, size: .medium, menuBarHeight: 32)
        #expect(frame == CGRect(x: 1512 - 40 - 240, y: 40, width: 240, height: 240))
        let top = ClockPalette.frame(in: CGRect(x: 0, y: 0, width: 1512, height: 982), position: .topLeft, size: .small, menuBarHeight: 32)
        #expect(abs(top.maxY - (982 - 32 - 160 / 6.0)) < 0.01)
        #expect(ClockPalette.make(for: nil, side: .light).hands != ClockPalette.make(for: nil, side: .light).face)
    }
}
