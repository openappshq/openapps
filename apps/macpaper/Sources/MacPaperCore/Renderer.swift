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
        return (0..<frames).map { i in
            render(generator: wallpaper.generator.atTimeOfDay(Double(i) / Double(frames)), of: wallpaper, side: i * 2 >= frames / 2 && i * 2 < frames * 3 / 2 ? .light : .dark, context: context, scale: scale)
        }
    }

    /// The one frame of a time-of-day document at this moment of the day.
    public func renderMoment(_ wallpaper: Wallpaper, dayFraction t: Double, context: RenderContext, scale: Double = 1) -> Raster {
        render(generator: wallpaper.generator.atTimeOfDay(t), of: wallpaper, side: t >= 0.25 && t < 0.75 ? .light : .dark, context: context, scale: scale)
    }

    private func render(generator: Generator, of wallpaper: Wallpaper, side: Side, context: RenderContext, scale: Double) -> Raster {
        let scale = min(max(scale, 0.01), 1)
        let context = context.scaled(by: scale)
        let target = context.size
        // Emerge moves radial and conic centers to the notch's bottom center.
        let notch = context.notch ?? .virtual
        let anchor = Point(x: notch.centerX, y: notch.height)
        var raster: Raster
        switch generator {
        case .gradient(var p):
            if wallpaper.composition == .emerge, p.kind != .linear { p.center = anchor }
            raster = Generators.gradient(p, size: target)
        case .mesh(let p):
            raster = Generators.mesh(p, seed: wallpaper.seed, size: target, emergeAt: wallpaper.composition == .emerge ? anchor : nil)
        case .pattern(var p):
            p.scale = max(2, p.scale * scale)
            raster = Generators.pattern(p, seed: wallpaper.seed, size: target)
        case .solid(let p):
            raster = Generators.solid(p, size: target)
        case .pixelize(var p):
            p.blockSize = max(1, Int((Double(p.blockSize) * scale).rounded()))
            let source = p.source.flatMap(images.raster(for:))
            raster = Pixelizer.render(p, source: source, seed: wallpaper.seed, size: target)
        case .dither(var p):
            p.cell = max(1, Int((Double(p.cell) * scale).rounded()))
            let source = p.source.flatMap(images.raster(for:))
            raster = Ditherer.render(p, source: source, seed: wallpaper.seed, size: target)
        }
        switch wallpaper.composition {
        case .contours:
            Generators.drawContours(on: &raster, notch: notch, ink: Generators.contrastingInk(for: generator), spacing: max(6, Double(target.width) / 40))
        case .pill where context.notch == nil:
            Generators.paintPill(on: &raster, notch: notch)
        default:
            break
        }
        Generators.applyFinish(wallpaper.finish, seed: wallpaper.seed, grain: wallpaper.grain, strip: context.menuBarStrip, side: side, to: &raster)
        return raster
    }
}
