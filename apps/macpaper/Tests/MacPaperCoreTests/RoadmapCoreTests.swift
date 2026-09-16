import Foundation
import ImageIO
@testable import MacPaperCore
import Testing

@Suite("OKLCH")
struct OKLCHTests {
    @Test("Round trips, mixes the short way round, and clips chroma into the gamut")
    func oklch() {
        for hex: UInt32 in [0xFF7A2F, 0x304BFF, 0x141414, 0xF8F8F8, 0x00FF00] {
            let color = RGBAColor(hex: hex)
            let back = OKLCH(color).color
            #expect(abs(back.red - color.red) < 0.01 && abs(back.green - color.green) < 0.01 && abs(back.blue - color.blue) < 0.01, Comment(rawValue: String(hex, radix: 16)))
        }
        #expect(OKLCH(.white).l > 0.99 && OKLCH(.black).l < 0.01)
        // Red to blue in OKLCH stays saturated in the middle; sRGB dips toward grey.
        let mid = OKLCH.mix(RGBAColor(hex: 0xFF0000), RGBAColor(hex: 0x0000FF), amount: 0.5)
        let srgbMid = RGBAColor(hex: 0xFF0000).mixed(with: RGBAColor(hex: 0x0000FF), amount: 0.5)
        #expect(OKLCH(mid).c > OKLCH(srgbMid).c)
        #expect(OKLCH.hueDelta(from: 350, to: 10) == 20 && OKLCH.hueDelta(from: 10, to: 350) == -20)
        // Out-of-gamut chroma comes back inside, hue and lightness kept.
        let loud = OKLCH(l: 0.6, c: 0.6, h: 140).color
        #expect((0...1).contains(loud.red) && (0...1).contains(loud.green) && (0...1).contains(loud.blue))
        #expect(abs(OKLCH(loud).l - 0.6) < 0.02 && abs(OKLCH.hueDelta(from: OKLCH(loud).h, to: 140)) < 3)
        // A grey takes the other color's hue when mixing.
        let fromGrey = OKLCH.mix(RGBAColor(hex: 0x808080), RGBAColor(hex: 0xFF0000), amount: 0.5)
        #expect(abs(OKLCH.hueDelta(from: OKLCH(fromGrey).h, to: OKLCH(RGBAColor(hex: 0xFF0000)).h)) < 2)
    }

    @Test("The accent palette keeps the hue and spans dark to light; a photo yields its dominant colors")
    func palettes() {
        let palette = AccentPalette.make(from: RGBAColor(hex: 0x304BFF))
        #expect(palette.count == 6)
        let hue = OKLCH(RGBAColor(hex: 0x304BFF)).h
        for (i, color) in palette.enumerated() where i != 4 {
            #expect(abs(OKLCH.hueDelta(from: OKLCH(color).h, to: hue)) < 4, Comment(rawValue: color.hexString))
        }
        #expect(abs(abs(OKLCH.hueDelta(from: OKLCH(palette[4]).h, to: hue)) - 180) < 4, "the complement")
        #expect(OKLCH(palette[0]).l < 0.25 && OKLCH(palette[5]).l > 0.9)
        // A grey accent still gets a usable palette.
        #expect(AccentPalette.make(from: RGBAColor(hex: 0x808080)).count == 6)
        var raster = Raster(width: 20, height: 10, fill: RGBAColor(hex: 0xFF0000))
        for y in 0..<10 { for x in 10..<20 { let i = (y * 20 + x) * 4; raster.pixels[i] = 0; raster.pixels[i + 2] = 255 } }
        let dominant = PaletteExtractor.dominantColors(of: raster, count: 2)
        #expect(dominant.map(\.hexString) == ["#0000FF", "#FF0000"], "dark to light")
    }
}

@Suite("Finishes and compositions")
struct FinishTests {
    static let size = PixelSize(width: 160, height: 100)
    static let renderer = WallpaperRenderer()
    static let base = Wallpaper(generator: .gradient(GradientParameters(kind: .linear, angle: 0, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1)

    static let golden: [(String, Wallpaper, String)] = [
        ("oklch gradient", Wallpaper(generator: .gradient(GradientParameters(kind: .linear, angle: 0, stops: [ColorStop(position: 0, color: RGBAColor(hex: 0xFF0000)), ColorStop(position: 1, color: RGBAColor(hex: 0x0000FF))], interpolation: .oklch)), seed: 1), "1d007b1b1bd02dbba2e1aad3310a9e151878874521ceb65794763ab5d32fcda1"),
        ("tint", Wallpaper(generator: base.generator, seed: 1, finish: Finish(tint: Tint(color: RGBAColor(hex: 0xFF7A2F), amount: 0.4))), "6743eb638ddb59c2ac954fc26344bdb9e637a3954a0643b9485edd22aa485267"),
        ("duotone", Wallpaper(generator: base.generator, seed: 1, finish: Finish(duotone: Duotone(shadow: RGBAColor(hex: 0x242B55), highlight: RGBAColor(hex: 0xFFD528)))), "59d98ec3251ee13f27b0d6e85a857e8feda23cad5996c89889abf00dd33e1a38"),
        ("gradient map", Wallpaper(generator: base.generator, seed: 1, finish: Finish(gradientMap: [ColorStop(position: 0, color: RGBAColor(hex: 0x163A29)), ColorStop(position: 0.5, color: RGBAColor(hex: 0x91DCB4)), ColorStop(position: 1, color: .white)])), "d735dbde628c5982b175ceb8f0c9bb91be13b0d746e5681332eaa8d5df71dec6"),
        ("top shade", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0xFFFFFF))), seed: 1, finish: Finish(topShade: 0.6)), "21ca93e97f0e5f0519f19d694af68cb3fe4b950bfe0f7b180a2f63431811e8ae"),
        ("contours", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x242B55))), seed: 1, composition: .contours), "b9610f822cf2710ef5a241dc778b441dfaa1d88ad49c9a48fddcf7a4d7c4dd68"),
        ("pill", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0xFFB48A))), seed: 1, composition: .pill), "48f63616f31736a8209227829bb68c73f6109923a22b0491ee0e38db018faa1a"),
        ("emerge mesh", Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.all[1])), seed: 4, composition: .emerge), "62a0c663d9589561f101df54887ed31e61ba36c15a79f3ab686b66882e4e9dc1"),
    ]

    @Test("Golden hashes for finishes and compositions", arguments: golden.indices)
    func goldenHash(index: Int) {
        let (name, wallpaper, expected) = Self.golden[index]
        let raster = Self.renderer.render(wallpaper, size: Self.size)
        #expect(raster.contentHash == expected, "\(name): \(raster.contentHash)")
    }

    @Test("True black is exact zeros only while plain")
    func trueBlack() {
        #expect(Wallpaper.trueBlack.isTrueBlack)
        let raster = Self.renderer.render(.trueBlack, size: PixelSize(width: 8, height: 8))
        #expect(raster.pixels.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 })
        var grainy = Wallpaper.trueBlack
        grainy.grain = 0.2
        #expect(!grainy.isTrueBlack)
        var tinted = Wallpaper.trueBlack
        tinted.finish.tint = Tint(color: .white, amount: 0.1)
        #expect(!tinted.isTrueBlack && !tinted.isPlain)
    }

    @Test("Tint mixes toward its color; duotone and the map follow luminance; the top shade darkens the strip only")
    func behaviors() {
        let tinted = Self.renderer.render(Wallpaper(generator: .solid(SolidParameters(color: .black)), seed: 1, finish: Finish(tint: Tint(color: .white, amount: 0.5))), size: PixelSize(width: 4, height: 4))
        #expect(tinted.pixel(x: 1, y: 1).hexString == "#808080")
        let duo = Self.renderer.render(Wallpaper(generator: Self.base.generator, seed: 1, finish: Finish(duotone: Duotone(shadow: RGBAColor(hex: 0xFF0000), highlight: RGBAColor(hex: 0x0000FF)))), size: PixelSize(width: 100, height: 4))
        #expect(duo.pixel(x: 0, y: 1).red > 0.95 && duo.pixel(x: 0, y: 1).blue < 0.05)
        #expect(duo.pixel(x: 99, y: 1).blue > 0.95 && duo.pixel(x: 99, y: 1).red < 0.05)
        let shaded = Self.renderer.render(Wallpaper(generator: .solid(SolidParameters(color: .white)), seed: 1, finish: Finish(topShade: 1), darkGenerator: .solid(SolidParameters(color: .white))), side: .dark, context: RenderContext(size: PixelSize(width: 4, height: 40), menuBarStrip: 4))
        #expect(shaded.pixel(x: 0, y: 0).red < 0.05, "black at the very top on the dark side")
        #expect(shaded.pixel(x: 0, y: 8).hexString == "#FFFFFF", "untouched past twice the strip")
        #expect(shaded.pixel(x: 0, y: 39).hexString == "#FFFFFF")
        let lightened = Self.renderer.render(Wallpaper(generator: .solid(SolidParameters(color: .black)), seed: 1, finish: Finish(topShade: 1)), side: .light, context: RenderContext(size: PixelSize(width: 4, height: 40), menuBarStrip: 4))
        #expect(lightened.pixel(x: 0, y: 0).red > 0.95, "white at the very top on the light side")
    }

    @Test("The readability check follows the side's text: dark text on the light side, light text on the dark side; a busy strip never reads")
    func readability() {
        let dark = Self.renderer.render(Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x141414))), seed: 1), size: PixelSize(width: 64, height: 32))
        #expect(MenuBarReadability.assess(dark, stripHeight: 4, side: .dark).reads, "white text on near-black")
        let onDarkLight = MenuBarReadability.assess(dark, stripHeight: 4, side: .light)
        #expect(!onDarkLight.reads && onDarkLight.verdict == "Menu bar: low contrast", "black text on near-black")
        let light = Self.renderer.render(Wallpaper(generator: .solid(SolidParameters(color: .white)), seed: 1), size: PixelSize(width: 64, height: 32))
        #expect(MenuBarReadability.assess(light, stripHeight: 4, side: .light).reads)
        #expect(!MenuBarReadability.assess(light, stripHeight: 4, side: .dark).reads)
        let busy = Self.renderer.render(Wallpaper(generator: .pattern(PatternParameters(kind: .checks, foreground: .white, background: .black, scale: 8)), seed: 1), size: PixelSize(width: 64, height: 32))
        #expect(!MenuBarReadability.assess(busy, stripHeight: 8, side: .light).reads && !MenuBarReadability.assess(busy, stripHeight: 8, side: .dark).reads, "spread too high")
        // Shading the top fixes a dark grey on the light side (toward white) and on the dark side (toward black).
        let grey = Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x555555))), seed: 1)
        let context = RenderContext(size: PixelSize(width: 64, height: 32), menuBarStrip: 4)
        #expect(!MenuBarReadability.assess(Self.renderer.render(grey, side: .light, context: context), stripHeight: 4, side: .light).reads)
        var shaded = grey
        shaded.finish.topShade = 0.9
        #expect(MenuBarReadability.assess(Self.renderer.render(shaded, side: .light, context: context), stripHeight: 4, side: .light).reads)
        #expect(MenuBarReadability.assess(Self.renderer.render(shaded, side: .dark, context: context), stripHeight: 4, side: .dark).reads)
    }

    @Test("Compositions: contours mark the notch's surroundings, the pill paints a notchless display only, emerge lifts the notch point")
    func compositions() {
        let notched = RenderContext(size: PixelSize(width: 300, height: 200), notch: NotchSpec(centerX: 0.5, width: 0.2, height: 0.05))
        let plain = RenderContext(size: PixelSize(width: 300, height: 200))
        let solid = Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x808080))), seed: 1, composition: .contours)
        let contoured = Self.renderer.render(solid, side: .light, context: notched)
        let marked = (10..<60).filter { contoured.pixel(x: 150, y: $0).hexString != "#808080" }
        #expect(marked.count >= 3, "bands under the notch")
        #expect(contoured.pixel(x: 5, y: 195).hexString == "#808080", "the far corner untouched")
        let pill = Wallpaper(generator: .solid(SolidParameters(color: .white)), seed: 1, composition: .pill)
        let painted = Self.renderer.render(pill, side: .light, context: plain)
        #expect(painted.pixel(x: 150, y: 2).luminance < 0.05, "black at the top center")
        #expect(painted.pixel(x: 10, y: 2).hexString == "#FFFFFF", "white beside it")
        #expect(painted.pixel(x: 150, y: 100).hexString == "#FFFFFF")
        let onNotched = Self.renderer.render(pill, side: .light, context: notched)
        #expect(onNotched.pixel(x: 150, y: 2).hexString == "#FFFFFF", "a real notch needs no paint")
        let mesh = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: [RGBAColor(hex: 0x141414), RGBAColor(hex: 0x91DCB4)])), seed: 9)
        var emerged = mesh
        emerged.composition = .emerge
        let a = Self.renderer.render(mesh, side: .light, context: notched)
        let b = Self.renderer.render(emerged, side: .light, context: notched)
        #expect(b.pixel(x: 150, y: 12).luminance >= a.pixel(x: 150, y: 12).luminance, "the notch point is the brightest color")
        #expect(a != b)
    }

    @Test("Framing: the focal point picks the crop, stretch fills both axes")
    func framing() {
        var source = Raster(width: 40, height: 10, fill: RGBAColor(hex: 0xFF0000))
        for y in 0..<10 { for x in 20..<40 { let i = (y * 40 + x) * 4; source.pixels[i] = 0; source.pixels[i + 2] = 255 } }
        let reference = ImageReference(fileName: "0123456789abcdef.png", contentHash: String(repeating: "0", count: 64))
        let renderer = WallpaperRenderer(images: MemoryImages([reference: source]))
        let square = PixelSize(width: 16, height: 16)
        let left = renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 4, fit: .fill, focus: Point(x: 0, y: 0.5))), seed: 1), size: square)
        #expect(left.pixel(x: 2, y: 8).hexString == "#FF0000" && left.pixel(x: 14, y: 8).hexString == "#FF0000", "the left edge kept: all red")
        let right = renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 4, fit: .fill, focus: Point(x: 1, y: 0.5))), seed: 1), size: square)
        #expect(right.pixel(x: 2, y: 8).hexString == "#0000FF" && right.pixel(x: 14, y: 8).hexString == "#0000FF", "the right edge kept: all blue")
        let stretched = renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 4, fit: .stretch)), seed: 1), size: square)
        #expect(stretched.pixel(x: 2, y: 8).hexString == "#FF0000" && stretched.pixel(x: 14, y: 8).hexString == "#0000FF", "both halves")
        let placement = Pixelizer.Placement(source: PixelSize(width: 40, height: 10), target: square, fit: .stretch)
        #expect(placement.scaleX == 0.4 && placement.scaleY == 1.6)
    }
}

@Suite("Dither lab")
struct DitherTests {
    /// A 64×32 horizontal ramp, black to white.
    static let ramp: Raster = {
        var raster = Raster(width: 64, height: 32)
        for y in 0..<32 { for x in 0..<64 { let i = (y * 64 + x) * 4; let v = UInt8(x * 4); raster.pixels[i] = v; raster.pixels[i + 1] = v; raster.pixels[i + 2] = v } }
        return raster
    }()
    static let reference = ImageReference(fileName: "abcdef0123456789.png", contentHash: String(repeating: "1", count: 64))
    static let renderer = WallpaperRenderer(images: MemoryImages([reference: ramp]))
    static let size = PixelSize(width: 128, height: 64)

    static let golden: [(DitherMode, Int, String)] = [
        (.bayer2, 2, "f6a904c01f2607537d5a7f1372a152d38e9a2ecb03ca2f3c4e8c143f7b3dda91"),
        (.bayer4, 2, "446933598194a5a6d69dbe4b05f27cac05dfd64382c7c802a8ac62d673a47e86"), (.bayer8, 1, "46d3f240aa61ea341f22fee4757ff00f57883497ab3b29adc8005ba41f0e3d8d"), (.floydSteinberg, 2, "aa2374fecd22309626bdc3ac52e6a057c80af388781f1035960464f864591f7f"), (.blueNoise, 2, "eef10296dbcf0b0d322e8af5a4f01609073da7ea518c67d647d9e125b58a49f5"), (.halftone, 8, "405122825ae568e3362afb2f720e6a329b4d73b8512016a5ad48ec44d23744ac"), (.ascii, 6, "cb9cc61471be9ca0978a5fbdc33e6c6a843f57e579d0d65b531d398a51cedf3c"),
    ]

    @Test("Golden hashes per mode", arguments: golden.indices)
    func goldenHash(index: Int) {
        let (mode, cell, expected) = Self.golden[index]
        let wallpaper = Wallpaper(generator: .dither(DitherParameters(source: Self.reference, mode: mode, cell: cell, ink: .white, paper: .black)), seed: 3)
        let raster = Self.renderer.render(wallpaper, size: Self.size)
        #expect(raster.contentHash == expected, "\(mode.rawValue): \(raster.contentHash)")
    }

    @Test("Two-color dithers use only ink and paper, denser where the source is darker")
    func twoColor() {
        for mode in [DitherMode.bayer4, .floydSteinberg, .blueNoise] {
            let raster = Self.renderer.render(Wallpaper(generator: .dither(DitherParameters(source: Self.reference, mode: mode, cell: 1, ink: RGBAColor(hex: 0x141414), paper: RGBAColor(hex: 0xFFF1EA))), seed: 1), size: PixelSize(width: 64, height: 32))
            var leftInk = 0, rightInk = 0
            for y in 0..<32 {
                for x in 0..<64 {
                    let p = raster.pixel(x: x, y: y)
                    #expect(p.hexString == "#141414" || p.hexString == "#FFF1EA", Comment(rawValue: mode.rawValue))
                    if p.hexString == "#141414" { if x < 32 { leftInk += 1 } else { rightInk += 1 } }
                }
            }
            #expect(leftInk > rightInk, Comment(rawValue: mode.rawValue))
        }
    }

    @Test("A palette dither uses only the reduced palette")
    func palette() {
        let raster = Self.renderer.render(Wallpaper(generator: .dither(DitherParameters(source: Self.reference, mode: .floydSteinberg, cell: 1, paletteSize: 4)), seed: 1), size: PixelSize(width: 64, height: 32))
        var used: Set<String> = []
        for y in stride(from: 0, to: 32, by: 3) { for x in 0..<64 { used.insert(raster.pixel(x: x, y: y).hexString) } }
        #expect(used.count <= 4 && used.count >= 2)
    }

    @Test("Bayer matrices and the blue-noise tile are permutations")
    func matrices() {
        #expect(Ditherer.bayer(2) == [0, 2, 3, 1])
        #expect(Set(Ditherer.bayer(4)) == Set(0..<16) && Set(Ditherer.bayer(8)) == Set(0..<64))
        let tile = BlueNoise.tile
        #expect(tile.count == 64 * 64)
        #expect(Set(tile.map { Int($0 * 4096) }).count == 4096, "every rank once")
        // Blue noise: neighbours differ a lot on average (no low-frequency clumps).
        var neighbourDelta = 0.0
        for i in 0..<(64 * 64 - 1) { neighbourDelta += abs(tile[i] - tile[i + 1]) }
        #expect(neighbourDelta / Double(64 * 64 - 1) > 0.25)
    }

    @Test("Halftone dots grow with darkness; ASCII draws glyphs in ink")
    func glyphs() {
        let halftone = Self.renderer.render(Wallpaper(generator: .dither(DitherParameters(source: Self.reference, mode: .halftone, cell: 8, ink: .black, paper: .white)), seed: 1), size: PixelSize(width: 128, height: 64))
        func inkCount(_ raster: Raster, from x0: Int, to x1: Int) -> Int {
            var n = 0
            for y in 0..<raster.height { for x in x0..<x1 where raster.pixel(x: x, y: y).luminance < 0.5 { n += 1 } }
            return n
        }
        #expect(inkCount(halftone, from: 0, to: 32) > inkCount(halftone, from: 96, to: 128))
        let ascii = Self.renderer.render(Wallpaper(generator: .dither(DitherParameters(source: Self.reference, mode: .ascii, cell: 5, ink: .black, paper: .white)), seed: 1), size: PixelSize(width: 128, height: 64))
        #expect(inkCount(ascii, from: 0, to: 32) > inkCount(ascii, from: 96, to: 128))
        #expect(ASCIIFont.ramp.count == 10 && ASCIIFont.ramp.allSatisfy { $0.count == 35 })
        #expect(ASCIIFont.glyph(forDarkness: 0).allSatisfy { !$0 } && ASCIIFont.glyph(forDarkness: 1).allSatisfy { $0 })
        // Without a source, the background.
        let none = Self.renderer.render(Wallpaper(generator: .dither(DitherParameters(source: nil, background: RGBAColor(hex: 0x123456))), seed: 1), size: PixelSize(width: 8, height: 8))
        #expect(none.pixel(x: 3, y: 3).hexString == "#123456")
    }
}

@Suite("Pairs")
struct PairTests {
    static let renderer = WallpaperRenderer()

    @Test("The dark side is derived darker with the hue kept; a custom dark side wins")
    func darkSide() {
        let light = Wallpaper.starter
        let dark = light.generator(for: .dark)
        for (a, b) in zip(light.generator.colors, dark.colors) {
            #expect(OKLCH(b).l < OKLCH(a).l)
            #expect(abs(OKLCH.hueDelta(from: OKLCH(a).h, to: OKLCH(b).h)) < 3)
        }
        var custom = light
        custom.darkGenerator = .solid(SolidParameters(color: .black))
        #expect(custom.generator(for: .dark) == .solid(SolidParameters(color: .black)) && custom.hasCustomDark)
        let lightRender = Self.renderer.render(light, side: .light, context: RenderContext(size: PixelSize(width: 16, height: 10)))
        let darkRender = Self.renderer.render(light, side: .dark, context: RenderContext(size: PixelSize(width: 16, height: 10)))
        #expect(darkRender.pixel(x: 8, y: 5).luminance < lightRender.pixel(x: 8, y: 5).luminance)
    }

    @Test("Time of day: noon is the brightest frame, midnight the darkest, the seed unchanged")
    func timeOfDay() {
        let frames = Self.renderer.renderFrames(.starter, frames: 8, context: RenderContext(size: PixelSize(width: 16, height: 10)))
        #expect(frames.count == 8)
        let brightness = frames.map { $0.pixel(x: 8, y: 5).luminance }
        #expect(brightness[4] == brightness.max() && brightness[0] == brightness.min())
        #expect(Self.renderer.renderMoment(.starter, dayFraction: 0.5, context: RenderContext(size: PixelSize(width: 16, height: 10))) == frames[4])
        #expect(DayClock.fraction(of: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian).withUTC) == 0)
    }

    @Test("HEIC pairs carry Apple's appearance and time records")
    func heic() throws {
        let light = Raster(width: 32, height: 20, fill: .white)
        let dark = Raster(width: 32, height: 20, fill: .black)
        let pair = try DynamicDesktop.appearancePair(light: light, dark: dark)
        #expect(DynamicDesktop.frameCount(in: pair) == 2)
        let record = try #require(DynamicDesktop.record(in: pair))
        #expect(record.name == "apr" && record.plist["l"] as? Int == 0 && record.plist["d"] as? Int == 1)
        let day = try DynamicDesktop.timeOfDay(frames: (0..<4).map { Raster(width: 8, height: 8, fill: RGBAColor(red: Double($0) / 4, green: 0, blue: 0)) })
        #expect(DynamicDesktop.frameCount(in: day) == 4)
        let h24 = try #require(DynamicDesktop.record(in: day))
        #expect(h24.name == "h24")
        let times = try #require(h24.plist["ti"] as? [[String: Any]])
        #expect(times.count == 4 && times[1]["t"] as? Double == 0.25 && times[1]["i"] as? Int == 1)
        #expect((h24.plist["ap"] as? [String: Int]) == ["l": 2, "d": 0])
        #expect(throws: DynamicDesktop.WriteError.self) { try DynamicDesktop.timeOfDay(frames: [light]) }
        #expect(DynamicDesktop.record(in: try #require(light.pngData())) == nil)
        #expect(PhoneCanvas.size == PixelSize(width: 1290, height: 2796))
    }
}

private extension Calendar {
    var withUTC: Calendar {
        var copy = self
        copy.timeZone = TimeZone(identifier: "UTC")!
        return copy
    }
}

@Suite("Sharing and never-show")
struct ShareTests {
    @Test("A link round-trips the whole document; junk, other schemes and oversized codes are refused")
    func roundTrip() throws {
        var document = Wallpaper.starter
        document.finish.tint = Tint(color: RGBAColor(hex: 0x123456), amount: 0.3)
        document.pair = .timeOfDay(frames: 16)
        document.composition = .contours
        document.darkGenerator = .solid(SolidParameters(color: RGBAColor(hex: 0x101010)))
        let url = try ShareCode.url(for: document)
        #expect(url.scheme == "macpaper" && url.host == "s")
        #expect(try ShareCode.decode(url: url) == document)
        #expect(url.absoluteString.count < 800)
        #expect(throws: ShareCode.DecodeError.notALink) { try ShareCode.decode(url: URL(string: "macpaper://activate?key=x")!) }
        #expect(throws: ShareCode.DecodeError.notALink) { try ShareCode.decode(url: URL(string: "https://openapps.space/macpaper/")!) }
        #expect(throws: ShareCode.DecodeError.corrupt) { try ShareCode.decode("bm90IGRlZmxhdGVk") }
        #expect(throws: ShareCode.DecodeError.tooLong) { try ShareCode.decode(String(repeating: "A", count: 9000)) }
        // A document that inflates past the limit is refused.
        let huge = ShareCode.base64url(ShareCode.compress(Data(repeating: 0x20, count: 200_000)))
        #expect(throws: ShareCode.DecodeError.self) { try ShareCode.decode(huge) }
    }

    @Test("The blocklist keeps hashes, filters candidates and clears")
    func blocklist() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appendingPathComponent("never.json")
        let store = BlocklistStore(fileURL: file)
        #expect(store.count == 0 && !store.contains(.starter))
        try store.add(.starter)
        #expect(store.contains(.starter) && store.count == 1)
        #expect(store.filter([.starter, .starter.reseeded(2)]) == [.starter.reseeded(2)])
        #expect(BlocklistStore(fileURL: file).contains(.starter), "reloaded")
        try store.removeAll()
        #expect(store.count == 0 && !BlocklistStore(fileURL: file).contains(.starter))
    }
}

@Suite("Apply, finished")
struct ApplyFinishedTests {
    static let notched = DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 32, height: 20), scale: 1, notchWidth: 6, isMain: true, topInset: 2)
    static let plain = DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 32, height: 20), scale: 1)
    static let external = DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 24, height: 16), scale: 1)

    @Test("A light/dark document applies as a HEIC pair; a refusing display gets the light still and a fallback mark")
    func pair() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applier = RecordingApplier()
        let wallpapers = WallpaperApplier(applier: applier, renderer: WallpaperRenderer(), cache: RenderCache(), directory: directory.url.appendingPathComponent("applied"))
        var document = Wallpaper.starter
        document.pair = .lightDark
        let images = try wallpapers.apply([Self.notched: document])
        #expect(images[0].format == .appearancePair && images[0].url.pathExtension == "heic")
        let data = try Data(contentsOf: images[0].url)
        #expect(DynamicDesktop.record(in: data)?.name == "apr" && DynamicDesktop.frameCount(in: data) == 2)
        applier.refusesHEIC = true
        let refused = try wallpapers.apply([Self.external: document])
        #expect(refused[0].format == .fallbackStill && refused[0].url.pathExtension == "png")
        #expect(applier.calls.count == 2, "the refused HEIC call is not recorded, the PNG is")
        // The swap: the dark side as a PNG, on request.
        let swapped = try wallpapers.apply([Self.external: document], side: .dark)
        #expect(swapped[0].format == .fallbackStill)
        let dark = try #require(Raster.decode(try Data(contentsOf: swapped[0].url)))
        let light = try #require(Raster.decode(try Data(contentsOf: refused[0].url)))
        #expect(dark.pixel(x: 12, y: 8).luminance < light.pixel(x: 12, y: 8).luminance)
    }

    @Test("A time-of-day document applies as an h24 HEIC with its frames; refused, the current moment")
    func timeOfDay() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let applier = RecordingApplier()
        let wallpapers = WallpaperApplier(applier: applier, renderer: WallpaperRenderer(), cache: RenderCache(), directory: directory.url.appendingPathComponent("applied"))
        var document = Wallpaper.starter
        document.pair = .timeOfDay(frames: 4)
        let images = try wallpapers.apply([Self.notched: document])
        let data = try Data(contentsOf: images[0].url)
        #expect(images[0].format == .timeOfDay && DynamicDesktop.record(in: data)?.name == "h24" && DynamicDesktop.frameCount(in: data) == 4)
        applier.refusesHEIC = true
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let refused = try wallpapers.apply([Self.notched: document], now: noon)
        #expect(refused[0].format == .fallbackStill)
        let still = try #require(Raster.decode(try Data(contentsOf: refused[0].url)))
        let expected = WallpaperRenderer().renderMoment(document, dayFraction: 0.5, context: Self.notched.renderContext)
        #expect(still == expected)
    }

    @Test("The pin re-applies only recorded displays that show something else, skipping per-Space ones and missing files")
    func pinPolicy() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("1-1.png"), b = directory.url.appendingPathComponent("2-1.png")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let recorded: [DisplayID: URL] = [1: a, 2: b, 3: directory.url.appendingPathComponent("gone.png")]
        var shown: [DisplayID: URL?] = [1: a, 2: directory.url.appendingPathComponent("apple.heic")]
        #expect(PinPolicy.displaysToReapply(recorded: recorded, current: { shown[$0] ?? nil }, excluded: [], connected: [1, 2, 3]) == [2])
        shown[1] = URL(fileURLWithPath: "/other.png")
        #expect(PinPolicy.displaysToReapply(recorded: recorded, current: { shown[$0] ?? nil }, excluded: [], connected: [1, 2, 3]) == [1, 2])
        #expect(PinPolicy.displaysToReapply(recorded: recorded, current: { shown[$0] ?? nil }, excluded: [1], connected: [1, 2, 3]) == [2], "per-Space display skipped")
        #expect(PinPolicy.displaysToReapply(recorded: recorded, current: { shown[$0] ?? nil }, excluded: [], connected: [2]) == [2], "only connected displays")
        #expect(PinPolicy.displaysToReapply(recorded: recorded, current: { _ in nil }, excluded: [], connected: [1, 2]) == [1, 2], "unknown: re-apply")
        // The pin hands over only files the applier wrote and listed for
        // that display: a planted file under the folder, a recorded file for
        // another display, a path outside, a symlink in — all refused.
        let recordingApplier = RecordingApplier()
        let wallpapers = WallpaperApplier(applier: recordingApplier, renderer: WallpaperRenderer(), cache: RenderCache(), directory: directory.url.appendingPathComponent("applied"))
        let applied = try wallpapers.apply([Self.notched: .trueBlack, Self.plain: .starter])
        let mine = try #require(applied.first { $0.display == Self.notched.id })
        let other = try #require(applied.first { $0.display == Self.plain.id })
        try wallpapers.reapply(mine.url, to: Self.notched.id)
        #expect(recordingApplier.calls.last == RecordingApplier.Call(url: mine.url, display: Self.notched.id))
        let before = recordingApplier.calls.count
        #expect(throws: WallpaperApplier.ApplyError.notOwned) { try wallpapers.reapply(other.url, to: Self.notched.id) }
        #expect(throws: WallpaperApplier.ApplyError.notOwned) { try wallpapers.reapply(a, to: 1) }
        let planted = directory.url.appendingPathComponent("applied/planted.png")
        try Data("p".utf8).write(to: planted)
        #expect(throws: WallpaperApplier.ApplyError.notOwned) { try wallpapers.reapply(planted, to: Self.notched.id) }
        let link = directory.url.appendingPathComponent("applied").appendingPathComponent(mine.url.lastPathComponent + ".link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        #expect(throws: WallpaperApplier.ApplyError.notOwned) { try wallpapers.reapply(link, to: Self.notched.id) }
        // Same name, another folder: the manifest's name is not enough.
        let elsewhere = directory.url.appendingPathComponent(mine.url.lastPathComponent)
        try Data("e".utf8).write(to: elsewhere)
        #expect(throws: WallpaperApplier.ApplyError.notOwned) { try wallpapers.reapply(elsewhere, to: Self.notched.id) }
        #expect(recordingApplier.calls.count == before)
    }

    @Test("The applied state records file, per-Space and fallback per display, and reads a version-1 file")
    func appliedState() throws {
        var state = AppliedState()
        let image = AppliedImage(display: 1, wallpaper: .starter, url: URL(fileURLWithPath: "/tmp/1-1.heic"), format: .fallbackStill)
        state.record(image, perSpace: true)
        #expect(state.file(for: 1)?.path == "/tmp/1-1.heic" && state.perSpaceDisplayIDs == [1] && state.fallbackDisplayIDs == [1])
        state.record(AppliedImage(display: 1, wallpaper: .starter, url: URL(fileURLWithPath: "/tmp/1-2.png"), format: .still), perSpace: false)
        #expect(state.perSpaceDisplayIDs.isEmpty && state.fallbackDisplayIDs.isEmpty && state.recordedFiles == [1: URL(fileURLWithPath: "/tmp/1-2.png")])
        let v1 = Data("{\"byDisplay\":{\"1\":{\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"1\"}}}".utf8)
        let decoded = try JSONDecoder().decode(AppliedState.self, from: v1)
        #expect(decoded.wallpaper(for: 1) == Wallpaper(generator: .solid(SolidParameters(color: .black)), seed: 1))
        #expect(decoded.fileByDisplay.isEmpty)
    }
}

@Suite("Document v2")
struct DocumentV2Tests {
    @Test("Version-1 JSON decodes with the defaults; version 2 round-trips every field")
    func versions() throws {
        let v1 = Data("{\"version\":1,\"generator\":{\"type\":\"gradient\",\"kind\":\"linear\",\"angle\":90,\"center\":{\"x\":0.5,\"y\":0.5},\"stops\":[{\"position\":0,\"color\":\"#000000\"},{\"position\":1,\"color\":\"#FFFFFF\"}]},\"seed\":\"5\",\"grain\":0.1}".utf8)
        let old = try Wallpaper.fromJSON(v1)
        #expect(old.pair == .still && old.composition == .none && old.finish.isEmpty && old.darkGenerator == nil)
        if case .gradient(let p) = old.generator { #expect(p.interpolation == .srgb) } else { Issue.record("not a gradient") }
        var full = Wallpaper.starter
        full.finish = Finish(tint: Tint(color: .white, amount: 0.2), duotone: Duotone(shadow: .black, highlight: .white), gradientMap: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)], topShade: 0.5)
        full.pair = .timeOfDay(frames: 4)
        full.composition = .pill
        full.darkGenerator = .dither(DitherParameters(source: nil, mode: .halftone, cell: 12, paletteSize: 5, focus: Point(x: 0.2, y: 0.8)))
        let data = try full.jsonData()
        #expect(try Wallpaper.fromJSON(data) == full)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"version\":2") && json.contains("\"pair\":{\"frames\":4,\"mode\":\"timeOfDay\"}") && json.contains("\"composition\":\"pill\""))
        #expect(throws: (any Error).self) { try Wallpaper.fromJSON(Data("{\"generator\":{\"type\":\"solid\",\"color\":\"#000\"},\"seed\":\"1\",\"pair\":{\"mode\":\"weekly\"}}".utf8)) }
        // A dither with an unknown frame count falls back to 8.
        let odd = try Wallpaper.fromJSON(Data("{\"generator\":{\"type\":\"solid\",\"color\":\"#000\"},\"seed\":\"1\",\"pair\":{\"mode\":\"timeOfDay\",\"frames\":7}}".utf8))
        #expect(odd.pair == .timeOfDay(frames: 8))
        #expect(Generator.default(.dither, colors: [.black, .white], source: nil).kind == .dither)
        #expect(Wallpaper.starter.generator.recolored { _ in .black }.colors.allSatisfy { $0 == .black })
    }
}

@Suite("Memory budgets")
struct MemoryBudgetTests {
    private static func frame(_ index: Int, in data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    @Test("The dither grid widens its cell until the samples fit the budget; small sizes keep the document's cell")
    func ditherBudget() {
        #expect(Ditherer.effectiveCell(1, for: PixelSize(width: 640, height: 400)) == 1)
        #expect(Ditherer.effectiveCell(1, for: PixelSize(width: 3024, height: 1964)) == 2, "the 14-inch at 2x")
        #expect(Ditherer.effectiveCell(1, for: PixelSize(width: 5120, height: 2880)) == 3, "5K")
        #expect(Ditherer.effectiveCell(1, for: PixelSize(width: 6016, height: 3384)) == 3, "6K")
        #expect(Ditherer.effectiveCell(8, for: PixelSize(width: 6016, height: 3384)) == 8, "a wider cell is kept")
        for (w, h) in [(6016, 3384), (5120, 2880), (3024, 1964)] {
            let cell = Ditherer.effectiveCell(1, for: PixelSize(width: w, height: h))
            #expect(((w + cell - 1) / cell) * ((h + cell - 1) / cell) <= Ditherer.maxSamples)
        }
    }

    @Test("A streamed time-of-day HEIC equals the one written from the whole set, frame by frame")
    func streamedFrames() throws {
        let document = Wallpaper.starter
        let context = RenderContext(size: PixelSize(width: 48, height: 30))
        let renderer = WallpaperRenderer()
        let all = renderer.renderFrames(document, frames: 5, context: context)
        var rendered: [Int] = []
        let streamed = try DynamicDesktop.timeOfDay(frameCount: 5) { index in
            rendered.append(index)
            return renderer.renderFrame(document, index: index, of: 5, context: context)
        }
        #expect(rendered == [0, 1, 2, 3, 4], "each frame asked for once, in order")
        // HEIC bytes are not stable run to run; the frames decode the same.
        let whole = try DynamicDesktop.timeOfDay(frames: all)
        #expect(DynamicDesktop.frameCount(in: streamed) == 5 && DynamicDesktop.record(in: streamed)?.name == "h24")
        for index in 0..<5 {
            let a = try #require(Self.frame(index, in: streamed)), b = try #require(Self.frame(index, in: whole))
            #expect(a.width == b.width && a.height == b.height && a.dataProvider?.data == b.dataProvider?.data, "frame \(index)")
        }
        #expect(throws: DynamicDesktop.WriteError.noFrames) { try DynamicDesktop.timeOfDay(frameCount: 1) { _ in all[0] } }
    }
}
