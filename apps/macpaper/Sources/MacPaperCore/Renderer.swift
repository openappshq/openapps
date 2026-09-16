import Foundation

/// Where a pixelize or dither document's source image comes from. The
/// app's store reads `imports/`; tests hand over rasters in memory.
public protocol ImageSource: Sendable {
    func raster(for reference: ImageReference) -> Raster?
}

/// An image source with nothing in it: pixelize renders its background.
public struct NoImages: ImageSource {
    public init() {}
    public func raster(for reference: ImageReference) -> Raster? { nil }
}

/// Rasters by reference, for tests and the preview harness.
public struct MemoryImages: ImageSource {
    public var rasters: [ImageReference: Raster]

    public init(_ rasters: [ImageReference: Raster] = [:]) {
        self.rasters = rasters
    }

    public func raster(for reference: ImageReference) -> Raster? { rasters[reference] }
}

/// The notch of the display a render is made for, in fractions of the
/// display: where its center is, how wide and how tall. A display without
/// one uses `virtual` (a 14" MacBook Pro's proportions at the top center)
/// for the compositions that draw one.
public struct NotchSpec: Hashable, Sendable {
    public var centerX: Double
    public var width: Double
    public var height: Double

    public init(centerX: Double, width: Double, height: Double) {
        self.centerX = centerX
        self.width = width
        self.height = height
    }

    /// A 14" MacBook Pro's notch: 252 of 1512 points wide, 32 of 982 tall.
    public static let virtual = NotchSpec(centerX: 0.5, width: 252.0 / 1512, height: 32.0 / 982)
}

/// What a render needs beyond the document: the size, the notch (nil on a
/// display without one) and how tall the menu-bar strip is in pixels (the
/// top shade and the readability check work on it).
public struct RenderContext: Hashable, Sendable {
    public var size: PixelSize
    public var notch: NotchSpec?
    public var menuBarStrip: Int

    public init(size: PixelSize, notch: NotchSpec? = nil, menuBarStrip: Int? = nil) {
        self.size = size
        self.notch = notch
        // Without a display: a 24-point bar at the size's implied scale.
        self.menuBarStrip = menuBarStrip ?? max(1, Int((Double(size.height) * 24 / 982).rounded()))
    }

    /// The context scaled for a preview, the strip scaled along.
    public func scaled(by factor: Double) -> RenderContext {
        RenderContext(size: size.scaled(by: factor), notch: notch, menuBarStrip: max(1, Int((Double(menuBarStrip) * factor).rounded())))
    }
}

extension DisplayInfo {
    /// The display's render context: its pixel size, its notch (from the
    /// notch width and the top inset) and its menu-bar strip in pixels.
    public var renderContext: RenderContext {
        let notch = notchWidth.map { NotchSpec(centerX: 0.5, width: $0 / pointSize.width, height: max(topInset, 24) / pointSize.height) }
        return RenderContext(size: pixelSize, notch: notch, menuBarStrip: Int((max(topInset, 24) * scale).rounded()))
    }
}

/// Renders a document at a size. `scale` shrinks the target for previews
/// (a 0.25 render of a 6-megapixel display is a 0.4-megapixel one) and
/// pattern, pixelize and dither scale their pixel parameters along, so a
/// preview looks like the real thing, smaller. The order is generator →
/// composition → tint → duotone → gradient map → grain → top shade.
public struct WallpaperRenderer: Sendable {
    public var images: any ImageSource

    public init(images: any ImageSource = NoImages()) {
        self.images = images
    }

    /// The light side at `size`, no notch: the tests' and the exports' entry.
    public func render(_ wallpaper: Wallpaper, size: PixelSize, scale: Double = 1) -> Raster {
        render(wallpaper, side: .light, context: RenderContext(size: size), scale: scale)
    }

    /// One side of the document for a display.
    public func render(_ wallpaper: Wallpaper, side: Side, context: RenderContext, scale: Double = 1) -> Raster {
        render(generator: wallpaper.generator(for: side), of: wallpaper, side: side, context: context, scale: scale)
    }

    /// The time-of-day frames, `frames` of them from midnight round the
    /// clock, the same seed throughout. Frame `frames / 2` is noon.
    public func renderFrames(_ wallpaper: Wallpaper, frames: Int, context: RenderContext, scale: Double = 1) -> [Raster] {
        let frames = max(2, frames)
        return (0..<frames).map { renderFrame(wallpaper, index: $0, of: frames, context: context, scale: scale) }
    }

    /// Frame `index` of a `frames`-frame time-of-day set, on its own.
    public func renderFrame(_ wallpaper: Wallpaper, index i: Int, of frames: Int, context: RenderContext, scale: Double = 1) -> Raster {
        let frames = max(2, frames)
        return render(generator: wallpaper.generator.atTimeOfDay(Double(i) / Double(frames)), of: wallpaper, side: i * 2 >= frames / 2 && i * 2 < frames * 3 / 2 ? .light : .dark, context: context, scale: scale)
    }

    /// The one frame of a time-of-day document at this moment of the day.
    public func renderMoment(_ wallpaper: Wallpaper, dayFraction t: Double, context: RenderContext, scale: Double = 1) -> Raster {
        render(generator: wallpaper.generator.atTimeOfDay(t), of: wallpaper, side: t >= 0.25 && t < 0.75 ? .light : .dark, context: context, scale: scale)
    }

    /// The document's structure for the quality gate: the plain render (no
    /// finish, no grain) at a size where its cells are still pixels — the
    /// canonical cell grid itself for a pixel field, a cell-based
    /// generator before its preview integrates, a 512-wide pattern, a
    /// 256-wide anything else. Texture is measured here, never on a
    /// thumbnail where a dither has averaged into a gradient.
    public func structure(_ wallpaper: Wallpaper, side: Side = .light, context: RenderContext) -> Raster {
        var plain = wallpaper
        plain.grain = 0
        plain.finish = Finish()
        let width = Double(context.size.width)
        switch plain.generator(for: side) {
        case .field(let p):
            let frame = FieldFrame(size: context.size, cell: p.cellSize)
            let ground = Self.baseRaster(plain.base(for: side), size: PixelSize(width: frame.columns, height: frame.rows), seed: plain.seed)
            let field = FieldEngine.canonical(p, seed: plain.seed, size: context.size)
            let colors = FieldEngine.cellColors(p, field: field, base: ground)
            return CellFill.filled(colors, columns: field.columns, rows: field.rows, cell: 1, size: PixelSize(width: field.columns, height: field.rows))
        case .dither(let p):
            let scale = min(1024 / width, Self.workingScale(1024 / width, unit: p.cell, floor: p.mode.isGlyphMode ? 6 : 3))
            return render(plain, side: side, context: context, scale: scale, integrate: false)
        case .pixelize(let p):
            let scale = min(1024 / width, Self.workingScale(1024 / width, unit: p.blockSize, floor: 6))
            return render(plain, side: side, context: context, scale: scale, integrate: false)
        case .pattern:
            return render(plain, side: side, context: context, scale: min(1, 512 / width))
        default:
            return render(plain, side: side, context: context, scale: min(1, 256 / width))
        }
    }

    private func render(generator: Generator, of wallpaper: Wallpaper, side: Side, context: RenderContext, scale: Double) -> Raster {
        render(generator: generator, of: wallpaper, side: side, context: context, scale: scale, integrate: true)
    }

    private func render(_ wallpaper: Wallpaper, side: Side, context: RenderContext, scale: Double, integrate: Bool) -> Raster {
        render(generator: wallpaper.generator(for: side), of: wallpaper, side: side, context: context, scale: scale, integrate: integrate)
    }

    /// `integrate` false leaves a cell-based preview at its working scale
    /// instead of averaging it down to the target.
    private func render(generator: Generator, of wallpaper: Wallpaper, side: Side, context: RenderContext, scale: Double, integrate: Bool) -> Raster {
        let scale = min(max(scale, 0.01), 1)
        // The display's size: a pixel field is sampled on its canonical
        // grid and filtered into a preview, never re-gridded.
        let canonical = context.size
        let context = context.scaled(by: scale)
        let target = context.size
        // Emerge moves radial and conic centers to the notch's bottom center.
        let notch = context.notch ?? .virtual
        let anchor = Point(x: notch.centerX, y: notch.height)
        let base = wallpaper.base(for: side)
        let seed = wallpaper.seed
        var raster: Raster
        switch generator {
        case .gradient(var p):
            if wallpaper.composition == .emerge, p.kind != .linear { p.center = anchor }
            raster = Generators.gradient(p, size: target)
        case .mesh(let p):
            raster = Generators.mesh(p, seed: seed, size: target, emergeAt: wallpaper.composition == .emerge ? anchor : nil)
        case .pattern(var p):
            p.scale = max(2, p.scale * scale)
            raster = Generators.pattern(p, seed: seed, size: target, base: Self.baseRaster(base, size: target, seed: seed))
        case .solid(let p):
            raster = Generators.solid(p, size: target)
        case .pixelize(var p):
            // A preview keeps at least six pixels per block, then integrates
            // the blocks down, so it shows the same picture as the final.
            let working = Self.workingScale(scale, unit: p.blockSize, floor: 6)
            let size = canonical.scaled(by: working)
            p.blockSize = max(1, Int((Double(p.blockSize) * working).rounded()))
            if let source = p.source.flatMap(images.raster(for:)) {
                raster = Pixelizer.render(p, source: source, seed: seed, size: size)
            } else if let ground = Self.baseRaster(base, size: Pixelizer.grid(block: p.blockSize, size: size), seed: seed) {
                // No photo: the base itself, one block per base pixel.
                p.fit = .stretch
                raster = Pixelizer.render(p, source: ground, seed: seed, size: size)
            } else {
                raster = Pixelizer.render(p, source: nil, seed: seed, size: size)
            }
            if integrate { raster = raster.areaResampled(to: target) }
        case .dither(var p):
            // Glyphs keep six pixels per cell in a preview, point dithers
            // three, then the cells integrate down.
            let working = Self.workingScale(scale, unit: p.cell, floor: p.mode.isGlyphMode ? 6 : 3)
            let size = canonical.scaled(by: working)
            p.cell = max(1, Int((Double(p.cell) * working).rounded()))
            if let source = p.source.flatMap(images.raster(for:)) {
                raster = Ditherer.render(p, source: source, seed: seed, size: size)
            } else if let ground = Self.baseRaster(base, size: Ditherer.grid(cell: p.cell, size: size), seed: seed) {
                // No photo: the base is what gets dithered, sampled once
                // per cell, never synthesised at full size and averaged back.
                p.fit = .stretch
                raster = Ditherer.render(p, source: ground, seed: seed, size: size)
            } else {
                raster = Ditherer.render(p, source: nil, seed: seed, size: size)
            }
            if integrate { raster = raster.areaResampled(to: target) }
        case .field(let p):
            let grid = FieldFrame(size: canonical, cell: p.cellSize)
            let ground = Self.baseRaster(base, size: PixelSize(width: grid.columns, height: grid.rows), seed: seed)
            raster = FieldEngine.render(p, seed: seed, size: canonical, target: target, base: ground)
        }
        switch wallpaper.composition {
        case .contours:
            Generators.drawContours(on: &raster, notch: notch, ink: Generators.contrastingInk(for: generator), spacing: max(6, Double(raster.width) / 40))
        case .pill where context.notch == nil:
            Generators.paintPill(on: &raster, notch: notch)
        default:
            break
        }
        Generators.applyFinish(wallpaper.finish(for: side), seed: seed, grain: wallpaper.grain, strip: context.menuBarStrip, side: side, pixelScale: scale, to: &raster)
        return raster
    }

    /// The scale a cell-based generator renders at for a preview at
    /// `scale`: never below `floor` pixels per `unit` (a cell or block at
    /// native size), never above native.
    static func workingScale(_ scale: Double, unit: Int, floor: Int) -> Double {
        guard scale < 1 else { return 1 }
        return min(1, max(scale, Double(floor) / Double(max(1, unit))))
    }

    /// The base at a size: nil for none, else its flat, gradient or mesh
    /// pixels (the mesh from the document's seed).
    static func baseRaster(_ base: BaseLayer, size: PixelSize, seed: UInt64) -> Raster? {
        switch base {
        case .none: nil
        case .solid(let color): Raster(size: size, fill: color)
        case .gradient(let p): Generators.gradient(p, size: size)
        case .mesh(let p): Generators.mesh(p, seed: seed, size: size)
        }
    }
}

extension Pixelizer {
    /// The block grid over a size.
    static func grid(block: Int, size: PixelSize) -> PixelSize {
        let block = max(1, block)
        return PixelSize(width: (size.width + block - 1) / block, height: (size.height + block - 1) / block)
    }
}

extension Ditherer {
    /// The sample grid over a size, at the cell actually used.
    static func grid(cell: Int, size: PixelSize) -> PixelSize {
        let cell = effectiveCell(cell, for: size)
        return PixelSize(width: (size.width + cell - 1) / cell, height: (size.height + cell - 1) / cell)
    }
}
