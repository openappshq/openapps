import Foundation

/// Where a pixelize document's source image comes from. The app's store
/// reads `imports/`; tests hand over rasters in memory.
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

/// Renders a document at a size. `scale` shrinks the target for previews
/// (a 0.25 render of a 6-megapixel display is a 0.4-megapixel one) and
/// pattern and pixelize scale their pixel parameters along, so a preview
/// looks like the real thing, smaller.
public struct WallpaperRenderer: Sendable {
    public var images: any ImageSource

    public init(images: any ImageSource = NoImages()) {
        self.images = images
    }

    public func render(_ wallpaper: Wallpaper, size: PixelSize, scale: Double = 1) -> Raster {
        let scale = min(max(scale, 0.01), 1)
        let target = size.scaled(by: scale)
        var raster: Raster
        switch wallpaper.generator {
        case .gradient(let p):
            raster = Generators.gradient(p, size: target)
        case .mesh(let p):
            raster = Generators.mesh(p, seed: wallpaper.seed, size: target)
        case .pattern(var p):
            p.scale = max(2, p.scale * scale)
            raster = Generators.pattern(p, seed: wallpaper.seed, size: target)
        case .solid(let p):
            raster = Generators.solid(p, size: target)
        case .pixelize(var p):
            p.blockSize = max(1, Int((Double(p.blockSize) * scale).rounded()))
            let source = p.source.flatMap(images.raster(for:))
            raster = Pixelizer.render(p, source: source, seed: wallpaper.seed, size: target)
        }
        Generators.applyGrain(wallpaper.grain, seed: wallpaper.seed, to: &raster)
        return raster
    }
}
