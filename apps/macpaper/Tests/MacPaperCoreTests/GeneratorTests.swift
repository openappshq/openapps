import Foundation
@testable import MacPaperCore
import Testing

/// Golden hashes per seed: every generator is software, so the same
/// document gives the same bytes on every Mac. A hash changes only when a
/// generator's arithmetic does, which is a deliberate change of every
/// wallpaper made with it.
@Suite("Generators")
struct GeneratorTests {
    static let size = PixelSize(width: 192, height: 120)
    static let renderer = WallpaperRenderer()

    static let golden: [(String, Wallpaper, String)] = [
        ("linear gradient", Wallpaper(generator: .gradient(GradientParameters(kind: .linear, angle: 135, stops: [
            ColorStop(position: 0, color: RGBAColor(hex: 0xFF7A2F)), ColorStop(position: 1, color: RGBAColor(hex: 0x304BFF)),
        ])), seed: 1), "93b0603e70cec007e0844cd38a1f82becf9bda63daa079a8fe18573357737007"),
        ("radial gradient", Wallpaper(generator: .gradient(GradientParameters(kind: .radial, center: Point(x: 0.3, y: 0.4), stops: [
            ColorStop(position: 0, color: .white), ColorStop(position: 0.5, color: RGBAColor(hex: 0x91DCB4)), ColorStop(position: 1, color: RGBAColor(hex: 0x163A29)),
        ])), seed: 1), "59612feef57a004bdcdfa2a2cd63d64d80d68f119774d673a4dfe0bddd74b00b"),
        ("conic gradient", Wallpaper(generator: .gradient(GradientParameters(kind: .conic, angle: 30, stops: [
            ColorStop(position: 0, color: RGBAColor(hex: 0xFFD528)), ColorStop(position: 0.5, color: RGBAColor(hex: 0xF3A0DC)), ColorStop(position: 1, color: RGBAColor(hex: 0xFFD528)),
        ])), seed: 1), "db624a43dda84956bd93ba8688cbf872904825c873a56d1dec24d669e2f55b8b"),
        ("mesh", Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: Palettes.all[1], jitter: 0.6, softness: 0.5)), seed: 42), "38558fefcf1dd71e3fe775978b259751b4cbe89cec1c40a77ddff756eb8b25a5"),
        ("dots", Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: .white, background: RGBAColor(hex: 0x242B55), scale: 24)), seed: 7), "cb23ec9b2419fb278577e5b8132650d21e7a89b1f14e84b449b0aeb0ce5530a9"),
        ("lines", Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: RGBAColor(hex: 0xFF7A2F), background: RGBAColor(hex: 0xFFF1EA), scale: 20, angle: 45)), seed: 7), "bf6a49a1b307a45d1ffc2179a82f7035e831c450d47d37c097039a196885ce83"),
        ("checks", Wallpaper(generator: .pattern(PatternParameters(kind: .checks, foreground: RGBAColor(hex: 0x141414), background: RGBAColor(hex: 0xEBEBEB), scale: 16, angle: 0)), seed: 7), "6edc0bed4fe5654e8bb1d1b3f2716b9beb47249956add6c31309dd008bb17380"),
        ("noise", Wallpaper(generator: .pattern(PatternParameters(kind: .noise, foreground: RGBAColor(hex: 0xA6B2FF), background: RGBAColor(hex: 0x242B55), scale: 40)), seed: 99), "6e0d9ea1c4cc5364d3889f3814aaa85dcc94a577f845957dad9cf10a46a6bc1c"),
        ("solid with grain", Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x236B48))), seed: 3, grain: 0.3), "8e6f9280bc0855337de7573af3e3da5e31aadbc7fca3c3b5376a41cc43c9f130"),
    ]

    @Test("Deterministic seeds give the golden hashes", arguments: golden.indices)
    func goldenHash(index: Int) {
        let (name, wallpaper, expected) = Self.golden[index]
        let raster = Self.renderer.render(wallpaper, size: Self.size)
        #expect(raster.size == Self.size)
        #expect(raster.contentHash == expected, "\(name): \(raster.contentHash)")
    }

    @Test("The same document renders the same bytes twice; another seed differs")
    func determinism() {
        let mesh = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.all[0])), seed: 5)
        let a = Self.renderer.render(mesh, size: Self.size)
        let b = Self.renderer.render(mesh, size: Self.size)
        #expect(a == b)
        let other = Self.renderer.render(mesh.reseeded(6), size: Self.size)
        #expect(a != other)
    }

    @Test("A linear gradient runs from the first stop to the last along its angle")
    func linearEnds() {
        let stops = [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)]
        let raster = Self.renderer.render(Wallpaper(generator: .gradient(GradientParameters(kind: .linear, angle: 0, stops: stops)), seed: 1), size: PixelSize(width: 100, height: 10))
        #expect(raster.pixel(x: 0, y: 5).red < 0.02)
        #expect(raster.pixel(x: 99, y: 5).red > 0.98)
        #expect(abs(raster.pixel(x: 50, y: 5).red - 0.5) < 0.02)
        // Rows are the same to within the ordered dither's one step: the
        // gradient runs along x only.
        #expect(abs(raster.pixel(x: 30, y: 0).red - raster.pixel(x: 30, y: 9).red) <= 1.01 / 255)
    }

    @Test("A radial gradient has the first stop at its center and the last at the far corner")
    func radialEnds() {
        let stops = [ColorStop(position: 0, color: .white), ColorStop(position: 1, color: .black)]
        let raster = Self.renderer.render(Wallpaper(generator: .gradient(GradientParameters(kind: .radial, center: .center, stops: stops)), seed: 1), size: PixelSize(width: 101, height: 101))
        #expect(raster.pixel(x: 50, y: 50).red > 0.98)
        #expect(raster.pixel(x: 0, y: 0).red < 0.03)
    }

    @Test("Stops are sorted and a single stop still renders")
    func stopNormalisation() {
        let unsorted = GradientParameters(kind: .linear, stops: [ColorStop(position: 1, color: .white), ColorStop(position: 0, color: .black)])
        #expect(unsorted.normalizedStops.map(\.position) == [0, 1])
        let single = GradientParameters(kind: .linear, stops: [ColorStop(position: 0.5, color: RGBAColor(hex: 0x123456))])
        let raster = Self.renderer.render(Wallpaper(generator: .gradient(single), seed: 1), size: PixelSize(width: 8, height: 8))
        #expect(raster.pixel(x: 0, y: 0).hexString == "#123456")
        #expect(raster.pixel(x: 7, y: 7).hexString == "#123456")
    }

    @Test("Mesh control points sit in their cells and use every palette color")
    func meshPoints() {
        let p = MeshParameters(columns: 3, rows: 3, colors: Palettes.all[2], jitter: 1, softness: 0.5)
        let points = Generators.meshPoints(p, seed: 11)
        #expect(points.count == 9)
        for (i, point) in points.enumerated() {
            let column = i % 3, row = i / 3
            #expect(point.x >= Double(column) / 3 && point.x <= Double(column + 1) / 3)
            #expect(point.y >= Double(row) / 3 && point.y <= Double(row + 1) / 3)
        }
        let used = Set(points.map { RGBAColor(red: $0.r, green: $0.g, blue: $0.b).hexString })
        #expect(used.count == Palettes.all[2].count)
    }

    @Test("Mesh pixels stay within the palette's channel range")
    func meshRange() {
        let colors = [RGBAColor(hex: 0x202040), RGBAColor(hex: 0x6080C0)]
        let raster = Self.renderer.render(Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: colors)), seed: 9), size: PixelSize(width: 64, height: 40))
        for y in stride(from: 0, to: 40, by: 7) {
            for x in stride(from: 0, to: 64, by: 9) {
                let c = raster.pixel(x: x, y: y)
                #expect(c.red >= 0x20 / 255.0 - 0.01 && c.red <= 0x60 / 255.0 + 0.01)
                #expect(c.blue >= 0x40 / 255.0 - 0.01 && c.blue <= 0xC0 / 255.0 + 0.01)
            }
        }
    }

    @Test("Checks alternate and dots are centered in their cells")
    func patterns() {
        let checks = Self.renderer.render(Wallpaper(generator: .pattern(PatternParameters(kind: .checks, foreground: .white, background: .black, scale: 8)), seed: 1), size: PixelSize(width: 32, height: 16))
        #expect(checks.pixel(x: 2, y: 2) == .black)
        #expect(checks.pixel(x: 10, y: 2) == .white)
        #expect(checks.pixel(x: 2, y: 10) == .white)
        #expect(checks.pixel(x: 10, y: 10) == .black)
        let dots = Self.renderer.render(Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: .white, background: .black, scale: 16)), seed: 1), size: PixelSize(width: 32, height: 32))
        #expect(dots.pixel(x: 8, y: 8) == .white)
        #expect(dots.pixel(x: 0, y: 0) == .black)
        #expect(dots.pixel(x: 15, y: 15) == .black)
    }

    @Test("Noise depends on the seed and stays between its colors")
    func noise() {
        let p = PatternParameters(kind: .noise, foreground: .white, background: .black, scale: 12)
        let a = Self.renderer.render(Wallpaper(generator: .pattern(p), seed: 1), size: PixelSize(width: 48, height: 24))
        let b = Self.renderer.render(Wallpaper(generator: .pattern(p), seed: 2), size: PixelSize(width: 48, height: 24))
        #expect(a != b)
        var minValue = 1.0, maxValue = 0.0
        for y in 0..<24 {
            for x in 0..<48 {
                let c = a.pixel(x: x, y: y)
                #expect(c.red == c.green && c.green == c.blue)
                minValue = min(minValue, c.red)
                maxValue = max(maxValue, c.red)
            }
        }
        #expect(maxValue - minValue > 0.2)
    }

    @Test("Grain is seeded, monochrome and bounded")
    func grain() {
        let base = Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x808080))), seed: 4, grain: 1)
        let a = Self.renderer.render(base, size: PixelSize(width: 40, height: 40))
        let b = Self.renderer.render(base.reseeded(5), size: PixelSize(width: 40, height: 40))
        #expect(a != b)
        var deviated = false
        for y in 0..<40 {
            for x in 0..<40 {
                let c = a.pixel(x: x, y: y)
                #expect(c.red == c.green && c.green == c.blue)
                #expect(abs(c.red - 0x80 / 255.0) <= 0.26)
                if abs(c.red - 0x80 / 255.0) > 0.05 { deviated = true }
            }
        }
        #expect(deviated)
        let none = Self.renderer.render(Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x808080))), seed: 4, grain: 0), size: PixelSize(width: 4, height: 4))
        #expect(none.pixel(x: 1, y: 1).hexString == "#808080")
    }

    @Test("A preview scale shrinks the target and scales pixel parameters along")
    func previewScale() {
        let dots = Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: .white, background: .black, scale: 32)), seed: 1)
        let full = Self.renderer.render(dots, size: PixelSize(width: 64, height: 64))
        let half = Self.renderer.render(dots, size: PixelSize(width: 64, height: 64), scale: 0.5)
        #expect(half.size == PixelSize(width: 32, height: 32))
        // The dot at the center of the first cell is at (16,16) full size and (8,8) at half.
        #expect(full.pixel(x: 16, y: 16) == .white)
        #expect(half.pixel(x: 8, y: 8) == .white)
        #expect(half.pixel(x: 0, y: 0) == .black)
    }

    @Test("Random documents come from the seed and never pixelize")
    func randomDocuments() {
        var a = SeededGenerator(seed: 123)
        var b = SeededGenerator(seed: 123)
        let first = (0..<20).map { _ in Wallpaper.random(using: &a) }
        let second = (0..<20).map { _ in Wallpaper.random(using: &b) }
        #expect(first == second)
        #expect(Set(first.map(\.generator.kind)).count > 1)
        #expect(!first.contains { $0.generator.kind == .pixelize })
        #expect(Set(first.map(\.seed)).count == 20)
    }
}

@Suite("Rasters")
struct RasterTests {
    @Test("Bilinear resampling keeps a flat color and blends an edge")
    func resample() {
        var raster = Raster(width: 4, height: 2, fill: .black)
        for x in 2..<4 { for y in 0..<2 { let i = (y * 4 + x) * 4; raster.pixels[i] = 255; raster.pixels[i + 1] = 255; raster.pixels[i + 2] = 255 } }
        let up = raster.resampled(to: PixelSize(width: 8, height: 4))
        #expect(up.pixel(x: 0, y: 0) == .black)
        #expect(up.pixel(x: 7, y: 3) == .white)
        let edge = up.pixel(x: 4, y: 1).red
        #expect(edge > 0.4 && edge < 1)
        #expect(raster.resampled(to: raster.size) == raster)
    }

    @Test("PNG round trip keeps every pixel")
    func pngRoundTrip() {
        let wallpaper = Wallpaper(generator: .gradient(GradientParameters(kind: .conic, stops: [ColorStop(position: 0, color: RGBAColor(hex: 0xFF0000)), ColorStop(position: 1, color: RGBAColor(hex: 0x0000FF))])), seed: 1, grain: 0.2)
        let raster = WallpaperRenderer().render(wallpaper, size: PixelSize(width: 24, height: 18))
        let png = try! #require(raster.pngData())
        let decoded = try! #require(Raster.decode(png))
        #expect(decoded == raster)
    }

    @Test("Colors parse and print as hex")
    func colors() {
        #expect(RGBAColor(hexString: "#FF7A2F")?.hexString == "#FF7A2F")
        #expect(RGBAColor(hexString: "ff7a2f")?.hexString == "#FF7A2F")
        #expect(RGBAColor(hexString: "#abc")?.hexString == "#AABBCC")
        #expect(RGBAColor(hexString: "#FF7A2F80")?.alpha ?? 0 > 0.5)
        #expect(RGBAColor(hexString: "nope") == nil)
        #expect(RGBAColor.black.mixed(with: .white, amount: 0.5).hexString == "#808080")
        #expect(RGBAColor.white.luminance > RGBAColor.black.luminance)
    }
}
