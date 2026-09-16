import Foundation
@testable import MacPaperCore
import Testing

@Suite("Wallpaper document")
struct WallpaperDocumentTests {
    @Test("JSON round trip for every generator")
    func roundTrip() throws {
        let documents: [Wallpaper] = [
            .starter,
            Wallpaper(generator: .mesh(MeshParameters(columns: 4, rows: 2, colors: Palettes.all[3], jitter: 0.3, softness: 0.9)), seed: .max, grain: 0.5),
            Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: .white, background: .black, scale: 33, angle: 30)), seed: 0),
            Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0xABCDEF))), seed: 12),
            Wallpaper(generator: .pixelize(PixelizeParameters(source: ImageReference(fileName: "0123456789abcdef01234567.png", contentHash: String(repeating: "c", count: 64)), blockSize: 24, paletteSize: 8, fit: .fit, background: .black)), seed: 77),
        ]
        for document in documents {
            let data = try document.jsonData()
            let decoded = try Wallpaper.fromJSON(data)
            #expect(decoded == document)
            // Byte-stable: the same document encodes to the same bytes.
            #expect(try decoded.jsonData() == data)
        }
    }

    @Test("The JSON shape is the documented one")
    func shape() throws {
        let json = try String(decoding: Wallpaper.starter.jsonData(), as: UTF8.self)
        #expect(json.hasPrefix("{\"composition\":\"none\",\"finish\":{\"topShade\":0},\"generator\":{\"angle\":135,\"center\":{\"x\":0.5,\"y\":0.5},\"interpolation\":\"oklch\",\"kind\":\"linear\",\"stops\":[{\"color\":\"#FF7A2F\",\"position\":0}"))
        #expect(json.contains("\"type\":\"gradient\""))
        #expect(json.contains("\"seed\":\"20260916\"") && json.contains("\"pair\":{\"mode\":\"still\"}"))
        #expect(json.hasSuffix("\"version\":2}"))
    }

    @Test("A newer version, a bad seed and an unknown generator are refused")
    func refusals() {
        #expect(throws: (any Error).self) { try Wallpaper.fromJSON(Data("{\"version\":3,\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"1\"}".utf8)) }
        #expect(throws: (any Error).self) { try Wallpaper.fromJSON(Data("{\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"x\"}".utf8)) }
        #expect(throws: (any Error).self) { try Wallpaper.fromJSON(Data("{\"generator\":{\"type\":\"plasma\"},\"seed\":\"1\"}".utf8)) }
        // Grain is optional and clamped.
        let plain = try? Wallpaper.fromJSON(Data("{\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"1\",\"grain\":4}".utf8))
        #expect(plain?.grain == 1)
    }

    @Test("Parameters clamp to their ranges")
    func clamping() {
        let mesh = MeshParameters(columns: 99, rows: 0, colors: [], jitter: 2, softness: -1)
        #expect(mesh.columns == 5 && mesh.rows == 2 && mesh.colors.count == 2 && mesh.jitter == 1 && mesh.softness == 0)
        let pixelize = PixelizeParameters(source: nil, blockSize: 1, paletteSize: 100)
        #expect(pixelize.blockSize == 4 && pixelize.paletteSize == 32)
        #expect(PatternParameters(kind: .dots, foreground: .white, background: .black, scale: 1).scale == 8)
    }

    @Test("Switching generators carries the colors over")
    func defaults() {
        let colors = [RGBAColor(hex: 0x111111), RGBAColor(hex: 0x222222), RGBAColor(hex: 0x333333)]
        if case .gradient(let p) = Generator.default(.gradient, colors: colors) { #expect(p.stops.map(\.color) == colors) } else { Issue.record("not a gradient") }
        if case .pattern(let p) = Generator.default(.pattern, colors: colors) { #expect(p.background == colors[0] && p.foreground == colors[1]) } else { Issue.record("not a pattern") }
        if case .solid(let p) = Generator.default(.solid, colors: []) { #expect(p.color == Palettes.all[0][0]) } else { Issue.record("not solid") }
        #expect(Generator.default(.mesh, colors: colors).colors == colors)
    }
}

@Suite("Pixelize")
struct PixelizeTests {
    /// A 16×8 source: left half red, right half blue.
    static let source: Raster = {
        var raster = Raster(width: 16, height: 8, fill: RGBAColor(hex: 0xFF0000))
        for y in 0..<8 { for x in 8..<16 { let i = (y * 16 + x) * 4; raster.pixels[i] = 0; raster.pixels[i + 2] = 255 } }
        return raster
    }()
    static let reference = ImageReference(fileName: "source.png", contentHash: "source")
    static let renderer = WallpaperRenderer(images: MemoryImages([reference: source]))

    @Test("Blocks average the source under them and the seed pins the bytes")
    func fill() {
        let wallpaper = Wallpaper(generator: .pixelize(PixelizeParameters(source: Self.reference, blockSize: 4, fit: .fill)), seed: 1)
        let raster = Self.renderer.render(wallpaper, size: PixelSize(width: 32, height: 16))
        #expect(raster.pixel(x: 3, y: 3).hexString == "#FF0000")
        #expect(raster.pixel(x: 31, y: 15).hexString == "#0000FF")
        // Block-uniform: every pixel of a block is the same.
        #expect(raster.pixel(x: 0, y: 0) == raster.pixel(x: 3, y: 3))
        #expect(raster.contentHash == "b30866324624e24ca771e31372f1cfd64ee0117dcc0c85a1648464c96c244243")
    }

    @Test("Fit leaves the background around the image and fill crops it")
    func fitAndFill() {
        let square = PixelSize(width: 16, height: 16)
        let fit = Self.renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: Self.reference, blockSize: 4, fit: .fit, background: RGBAColor(hex: 0x00FF00))), seed: 1), size: square)
        #expect(fit.pixel(x: 1, y: 1).hexString == "#00FF00")
        #expect(fit.pixel(x: 1, y: 8).hexString == "#FF0000")
        #expect(fit.pixel(x: 14, y: 8).hexString == "#0000FF")
        let fill = Self.renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: Self.reference, blockSize: 4, fit: .fill)), seed: 1), size: square)
        // The 16×8 source scaled to cover 16×16 shows its middle 8 columns.
        #expect(fill.pixel(x: 1, y: 1).hexString == "#FF0000")
        #expect(fill.pixel(x: 14, y: 14).hexString == "#0000FF")
    }

    @Test("A palette reduces the block colors to that many")
    func palette() {
        var gradient = Raster(width: 64, height: 4)
        for y in 0..<4 { for x in 0..<64 { let i = (y * 64 + x) * 4; gradient.pixels[i] = UInt8(x * 4); gradient.pixels[i + 1] = UInt8(x * 4); gradient.pixels[i + 2] = UInt8(x * 4) } }
        let reference = ImageReference(fileName: "g.png", contentHash: "g")
        let renderer = WallpaperRenderer(images: MemoryImages([reference: gradient]))
        let free = renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 4)), seed: 1), size: PixelSize(width: 64, height: 4))
        let reduced = renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 4, paletteSize: 3)), seed: 1), size: PixelSize(width: 64, height: 4))
        func colors(_ raster: Raster) -> Set<String> { Set((0..<16).map { raster.pixel(x: $0 * 4, y: 0).hexString }) }
        #expect(colors(free).count == 16)
        #expect(colors(reduced).count == 3)
    }

    @Test("Without a source the background renders and a missing reference does the same")
    func missing() {
        let none = Self.renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: nil, background: RGBAColor(hex: 0x123456))), seed: 1), size: PixelSize(width: 8, height: 8))
        #expect(none.pixel(x: 4, y: 4).hexString == "#123456")
        let missing = Self.renderer.render(Wallpaper(generator: .pixelize(PixelizeParameters(source: ImageReference(fileName: "x", contentHash: "x"), background: RGBAColor(hex: 0x123456))), seed: 1), size: PixelSize(width: 8, height: 8))
        #expect(missing == none)
    }

    @Test("Median cut splits the widest channel and is deterministic")
    func medianCut() {
        let colors = [RGBAColor(hex: 0x000000), RGBAColor(hex: 0x100000), RGBAColor(hex: 0xF00000), RGBAColor(hex: 0xFF0000)]
        let palette = MedianCut.palette(of: colors, count: 2)
        #expect(palette.count == 2)
        #expect(palette == MedianCut.palette(of: colors, count: 2))
        #expect(MedianCut.nearest(to: RGBAColor(hex: 0x080000), in: palette) == palette[0])
        #expect(MedianCut.palette(of: [RGBAColor.white, .white], count: 4).count == 1)
        #expect(MedianCut.palette(of: [], count: 4).isEmpty)
    }
}

@Suite("Export")
struct ExportTests {
    let renderer = WallpaperRenderer()
    let size = PixelSize(width: 320, height: 200)

    @Test("Gradients export as SVG gradients")
    func gradients() {
        let linear = WallpaperExport.svg(Wallpaper(generator: .gradient(GradientParameters(kind: .linear, angle: 0, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1), size: size, renderer: renderer)
        #expect(linear.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(linear.contains("<linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"100\" x2=\"320\" y2=\"100\">"))
        #expect(linear.contains("<stop offset=\"0%\" stop-color=\"#000000\"/><stop offset=\"100%\" stop-color=\"#FFFFFF\"/>"))
        #expect(linear.contains("fill=\"url(#g)\""))
        #expect(!linear.contains("<image"))
        #expect(!linear.contains("grain"))
        let radial = WallpaperExport.svg(Wallpaper(generator: .gradient(GradientParameters(kind: .radial, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1), size: size, renderer: renderer)
        #expect(radial.contains("<radialGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" cx=\"160\" cy=\"100\""))
        let conic = WallpaperExport.svg(Wallpaper(generator: .gradient(GradientParameters(kind: .conic, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1), size: size, renderer: renderer)
        #expect(conic.components(separatedBy: "<path ").count == 91)
    }

    @Test("Patterns are SVG patterns, noise and pixelize embed the render, grain is a filter")
    func patternsAndEmbeds() {
        let dots = WallpaperExport.svg(Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: .white, background: .black, scale: 20)), seed: 1), size: size, renderer: renderer)
        #expect(dots.contains("<pattern id=\"p\" width=\"20\" height=\"20\" patternUnits=\"userSpaceOnUse\"><circle"))
        let lines = WallpaperExport.svg(Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: .white, background: .black, scale: 20, angle: 45)), seed: 1), size: size, renderer: renderer)
        #expect(lines.contains("patternTransform=\"rotate(45 160 100)\""))
        let checks = WallpaperExport.svg(Wallpaper(generator: .pattern(PatternParameters(kind: .checks, foreground: .white, background: .black, scale: 20)), seed: 1), size: size, renderer: renderer)
        #expect(checks.contains("width=\"40\" height=\"40\""))
        let noise = WallpaperExport.svg(Wallpaper(generator: .pattern(PatternParameters(kind: .noise, foreground: .white, background: .black, scale: 20)), seed: 1, grain: 0.2), size: size, renderer: renderer)
        #expect(noise.contains("<image width=\"320\" height=\"200\" style=\"image-rendering:pixelated\" xlink:href=\"data:image/png;base64,"))
        #expect(noise.contains("<filter id=\"grain\"") && noise.contains("feTurbulence"))
        let pixelize = WallpaperExport.svg(Wallpaper(generator: .pixelize(PixelizeParameters(source: nil, background: RGBAColor(hex: 0x123456))), seed: 1), size: size, renderer: renderer)
        #expect(pixelize.contains("<image "))
        let solid = WallpaperExport.svg(Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x123456))), seed: 1), size: size, renderer: renderer)
        #expect(solid.contains("<rect width=\"320\" height=\"200\" fill=\"#123456\"/>"))
        let mesh = WallpaperExport.svg(Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.all[0])), seed: 1), size: size, renderer: renderer)
        #expect(mesh.components(separatedBy: "<radialGradient").count == 5)
        #expect(mesh.contains("feGaussianBlur"))
    }

    @Test("SVG text is byte-stable for a seed")
    func golden() {
        let svg = WallpaperExport.svg(Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.all[4])), seed: 8, grain: 0.1), size: PixelSize(width: 100, height: 50), renderer: renderer)
        let again = WallpaperExport.svg(Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.all[4])), seed: 8, grain: 0.1), size: PixelSize(width: 100, height: 50), renderer: renderer)
        #expect(svg == again)
        #expect(svg.hasSuffix("</svg>\n"))
    }

    @Test("PNG export decodes to the render and file names carry generator and seed")
    func png() throws {
        let wallpaper = Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x0000FF))), seed: 5)
        let data = try #require(WallpaperExport.png(wallpaper, size: PixelSize(width: 10, height: 10), renderer: renderer))
        let decoded = try #require(Raster.decode(data))
        #expect(decoded.pixel(x: 5, y: 5).hexString == "#0000FF")
        #expect(WallpaperExport.fileName(for: wallpaper, format: .png) == "macPaper-solid-5.png")
        #expect(WallpaperExport.fileName(for: wallpaper, format: .svg) == "macPaper-solid-5.svg")
    }
}
