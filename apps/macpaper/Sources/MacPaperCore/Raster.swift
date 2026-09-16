import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Data {
    /// SHA-256 as 64 lowercase hex characters.
    public var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

/// A size in pixels, the unit renders are made in: a display's points times
/// its backing scale.
public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public init(points: CGSize, scale: CGFloat) {
        self.init(width: Int((points.width * scale).rounded()), height: Int((points.height * scale).rounded()))
    }

    /// The same aspect, scaled by `factor` and rounded to whole pixels.
    public func scaled(by factor: Double) -> PixelSize {
        PixelSize(width: Int((Double(width) * factor).rounded()), height: Int((Double(height) * factor).rounded()))
    }

    /// A size with the same aspect whose width is at most `maxWidth`.
    public func fitting(width maxWidth: Int) -> PixelSize {
        guard width > maxWidth else { return self }
        return scaled(by: Double(maxWidth) / Double(width))
    }

    public var aspectRatio: Double { Double(width) / Double(height) }
    public var pixelCount: Int { width * height }
}

/// An 8-bit RGBA bitmap, row-major, straight alpha. Every generator writes
/// one, and it becomes a `CGImage` only at the edge (preview, PNG, the
/// applied file), so the pixels a golden hash covers are the ones made here.
public struct Raster: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: RGBAColor = .black) {
        self.width = max(1, width)
        self.height = max(1, height)
        let r = RGBAColor.byte(fill.red), g = RGBAColor.byte(fill.green), b = RGBAColor.byte(fill.blue), a = RGBAColor.byte(fill.alpha)
        var pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            var i = 0
            while i < buffer.count {
                buffer[i] = r; buffer[i + 1] = g; buffer[i + 2] = b; buffer[i + 3] = a
                i += 4
            }
        }
        self.pixels = pixels
    }

    public init(size: PixelSize, fill: RGBAColor = .black) {
        self.init(width: size.width, height: size.height, fill: fill)
    }

    /// Wraps existing RGBA bytes; `pixels.count` must be `width * height * 4`.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var byteCount: Int { pixels.count }

    @inline(__always)
    public func pixel(x: Int, y: Int) -> RGBAColor {
        let i = (y * width + x) * 4
        return RGBAColor(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255, alpha: Double(pixels[i + 3]) / 255)
    }

    /// SHA-256 of the pixel bytes: the golden value the tests pin per seed.
    public var contentHash: String {
        Data(pixels).sha256Hex
    }

    /// Bilinear resampling to another size, in software: used to bring a
    /// mesh computed at a lower resolution up to the display's, so the
    /// result stays the same everywhere.
    public func resampled(to target: PixelSize) -> Raster {
        if target == size { return self }
        var out = Raster(size: target)
        let sx = Double(width) / Double(target.width)
        let sy = Double(height) / Double(target.height)
        let src = pixels
        let sw = width, sh = height
        out.pixels.withUnsafeMutableBufferPointer { dst in
            src.withUnsafeBufferPointer { s in
                for y in 0..<target.height {
                    let fy = (Double(y) + 0.5) * sy - 0.5
                    let y0 = max(0, min(sh - 1, Int(fy.rounded(.down))))
                    let y1 = min(sh - 1, y0 + 1)
                    let wy = max(0, min(1, fy - Double(y0)))
                    for x in 0..<target.width {
                        let fx = (Double(x) + 0.5) * sx - 0.5
                        let x0 = max(0, min(sw - 1, Int(fx.rounded(.down))))
                        let x1 = min(sw - 1, x0 + 1)
                        let wx = max(0, min(1, fx - Double(x0)))
                        let i00 = (y0 * sw + x0) * 4, i10 = (y0 * sw + x1) * 4
                        let i01 = (y1 * sw + x0) * 4, i11 = (y1 * sw + x1) * 4
                        let o = (y * target.width + x) * 4
                        for c in 0..<4 {
                            let top = Double(s[i00 + c]) * (1 - wx) + Double(s[i10 + c]) * wx
                            let bottom = Double(s[i01 + c]) * (1 - wx) + Double(s[i11 + c]) * wx
                            dst[o + c] = UInt8(min(255, max(0, (top * (1 - wy) + bottom * wy).rounded())))
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - CoreGraphics

    public var cgImage: CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Reads any `CGImage` into straight RGBA, through one sRGB draw. This
    /// is the import path (pixelize sources); renders never go through it.
    public init?(cgImage: CGImage) {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        // Premultiplied by the draw; opaque sources (every wallpaper source
        // in practice) are unaffected, and a transparent pixel un-premultiplies.
        var i = 0
        while i < pixels.count {
            let a = pixels[i + 3]
            if a != 0, a != 255 {
                let f = 255.0 / Double(a)
                pixels[i] = UInt8(min(255, Double(pixels[i]) * f))
                pixels[i + 1] = UInt8(min(255, Double(pixels[i + 1]) * f))
                pixels[i + 2] = UInt8(min(255, Double(pixels[i + 2]) * f))
            }
            i += 4
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// PNG bytes through ImageIO, lossless.
    public func pngData() -> Data? {
        guard let image = cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decodes a PNG, JPEG, HEIC, TIFF or any other ImageIO format at its
    /// own size; orientation metadata is applied. For files of unknown size
    /// use `decode(at:maxPixelSize:)`, which never allocates the full image.
    public static func decode(_ data: Data) -> Raster? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Raster(cgImage: image.oriented(source: source))
    }

    /// The default bound for imports: the width of a 6K display. A source
    /// larger than that is scaled down by ImageIO while decoding, so a
    /// 20,000-pixel photo never becomes a 1.6 GB buffer.
    public static let importMaxPixelSize = 6016

    /// Decodes a file through ImageIO's bounded thumbnail path: the longer
    /// edge is at most `maxPixelSize`, orientation is applied by ImageIO,
    /// and the full-size image is never materialised.
    public static func decode(at url: URL, maxPixelSize: Int = importMaxPixelSize) -> Raster? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source: source, maxPixelSize: maxPixelSize)
    }

    public static func decode(_ data: Data, maxPixelSize: Int) -> Raster? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source: source, maxPixelSize: maxPixelSize)
    }

    private static func decode(source: CGImageSource, maxPixelSize: Int) -> Raster? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Raster(cgImage: image)
    }
}

private extension CGImage {
    /// Bakes the EXIF orientation in, so a photo from a phone pixelizes the
    /// way it is seen.
    func oriented(source: CGImageSource) -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32, raw > 1, raw <= 8 else { return self }
        let swapsAxes = raw >= 5
        let width = swapsAxes ? height : self.width
        let height = swapsAxes ? self.width : self.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return self }
        var transform = CGAffineTransform.identity
        switch raw {
        case 2: transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(width), y: 0)
        case 3: transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case 4: transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height))
        case 5: transform = CGAffineTransform(translationX: CGFloat(width), y: 0).rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
        case 6: transform = CGAffineTransform(translationX: CGFloat(width), y: 0).rotated(by: .pi / 2)
        case 7: transform = CGAffineTransform(translationX: 0, y: CGFloat(height)).rotated(by: -.pi / 2).scaledBy(x: 1, y: -1)
        case 8: transform = CGAffineTransform(translationX: 0, y: CGFloat(height)).rotated(by: -.pi / 2)
        default: break
        }
        context.concatenate(transform)
        context.draw(self, in: CGRect(x: 0, y: 0, width: self.width, height: self.height))
        return context.makeImage() ?? self
    }
}
