import Foundation

/// Turns an image into blocks: the source is placed on the display (fill or
/// fit), every block averages the source pixels under it, the block colors
/// are optionally reduced to a palette (median cut), and each block is
/// filled. Straight from the source raster, without an intermediate scaled
/// image, so nothing here depends on a system resampler.
public enum Pixelizer {
    public static func render(_ p: PixelizeParameters, source: Raster?, seed: UInt64, size: PixelSize) -> Raster {
        guard let source else { return Raster(size: size, fill: p.background) }
        let block = max(1, p.blockSize)
        let columns = (size.width + block - 1) / block
        let rows = (size.height + block - 1) / block
        let placement = Placement(source: source.size, target: size, fit: p.fit)
        var colors = blockAverages(source: source, placement: placement, block: block, columns: columns, rows: rows, background: p.background)
        if let count = p.paletteSize, count > 0 {
            let palette = MedianCut.palette(of: colors, count: count)
            colors = colors.map { MedianCut.nearest(to: $0, in: palette) }
        }
        var raster = Raster(size: size)
        let w = size.width, h = size.height
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<rows {
                for column in 0..<columns {
                    let c = colors[row * columns + column]
                    let r = RGBAColor.byte(c.red), g = RGBAColor.byte(c.green), b = RGBAColor.byte(c.blue)
                    let x0 = column * block, y0 = row * block
                    for y in y0..<min(h, y0 + block) {
                        var o = (y * w + x0) * 4
                        for _ in x0..<min(w, x0 + block) {
                            out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = 255
                            o += 4
                        }
                    }
                }
            }
        }
        return raster
    }

    /// Where the source sits on the target, in target pixels.
    public struct Placement: Equatable, Sendable {
        /// Target pixels per source pixel.
        public let scale: Double
        /// Target-space origin of the source's top-left corner.
        public let originX: Double
        public let originY: Double

        public init(source: PixelSize, target: PixelSize, fit: ImageFit) {
            let sx = Double(target.width) / Double(source.width)
            let sy = Double(target.height) / Double(source.height)
            scale = fit == .fill ? max(sx, sy) : min(sx, sy)
            originX = (Double(target.width) - Double(source.width) * scale) / 2
            originY = (Double(target.height) - Double(source.height) * scale) / 2
        }
    }

    /// The average source color under each block; blocks outside the source
    /// (fit mode) are the background, and a block half outside blends it.
    static func blockAverages(source: Raster, placement: Placement, block: Int, columns: Int, rows: Int, background: RGBAColor) -> [RGBAColor] {
        var result: [RGBAColor] = []
        result.reserveCapacity(columns * rows)
        let sw = source.width, sh = source.height
        let inv = 1 / placement.scale
        source.pixels.withUnsafeBufferPointer { s in
            for row in 0..<rows {
                for column in 0..<columns {
                    // The block's rect in source pixels.
                    let tx0 = Double(column * block), ty0 = Double(row * block)
                    let tx1 = tx0 + Double(block), ty1 = ty0 + Double(block)
                    let sx0 = (tx0 - placement.originX) * inv, sy0 = (ty0 - placement.originY) * inv
                    let sx1 = (tx1 - placement.originX) * inv, sy1 = (ty1 - placement.originY) * inv
                    let x0 = max(0, Int(sx0.rounded(.down))), y0 = max(0, Int(sy0.rounded(.down)))
                    let x1 = min(sw, Int(sx1.rounded(.up))), y1 = min(sh, Int(sy1.rounded(.up)))
                    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
                    if x1 > x0, y1 > y0 {
                        for y in y0..<y1 {
                            var i = (y * sw + x0) * 4
                            for _ in x0..<x1 {
                                r += Double(s[i]); g += Double(s[i + 1]); b += Double(s[i + 2]); n += 1
                                i += 4
                            }
                        }
                    }
                    if n == 0 {
                        result.append(background)
                        continue
                    }
                    // How much of the block the source covers: outside the
                    // source the background shows.
                    let coveredW = max(0, min(sx1, Double(sw)) - max(sx0, 0))
                    let coveredH = max(0, min(sy1, Double(sh)) - max(sy0, 0))
                    let coverage = min(1, (coveredW * coveredH) / ((sx1 - sx0) * (sy1 - sy0)))
                    let average = RGBAColor(red: r / n / 255, green: g / n / 255, blue: b / n / 255)
                    result.append(background.mixed(with: average, amount: coverage))
                }
            }
        }
        return result
    }
}

/// Median-cut palette reduction: split the box with the widest channel at
/// its median until there are `count` boxes, each box's mean is a palette
/// entry. Deterministic: ties break by channel order and stable sorting.
public enum MedianCut {
    public static func palette(of colors: [RGBAColor], count: Int) -> [RGBAColor] {
        guard !colors.isEmpty else { return [] }
        let count = max(1, count)
        var boxes: [[RGBAColor]] = [colors]
        while boxes.count < count {
            // The box with the widest range; a box of one color cannot split.
            var best = -1, bestRange = 0.0, bestChannel = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let (channel, range) = widestChannel(box)
                if range > bestRange { best = i; bestRange = range; bestChannel = channel }
            }
            guard best >= 0, bestRange > 0 else { break }
            let box = boxes[best]
            let sorted = box.sorted { component($0, bestChannel) < component($1, bestChannel) }
            let mid = sorted.count / 2
            boxes[best] = Array(sorted[..<mid])
            boxes.append(Array(sorted[mid...]))
        }
        return boxes.map { box in
            let n = Double(box.count)
            return RGBAColor(
                red: box.reduce(0) { $0 + $1.red } / n,
                green: box.reduce(0) { $0 + $1.green } / n,
                blue: box.reduce(0) { $0 + $1.blue } / n
            )
        }
    }

    public static func nearest(to color: RGBAColor, in palette: [RGBAColor]) -> RGBAColor {
        var best = color, bestDistance = Double.infinity
        for entry in palette {
            let dr = entry.red - color.red, dg = entry.green - color.green, db = entry.blue - color.blue
            let d = dr * dr + dg * dg + db * db
            if d < bestDistance { bestDistance = d; best = entry }
        }
        return best
    }

    private static func widestChannel(_ box: [RGBAColor]) -> (Int, Double) {
        var lo = [1.0, 1.0, 1.0], hi = [0.0, 0.0, 0.0]
        for c in box {
            for channel in 0..<3 {
                let v = component(c, channel)
                lo[channel] = min(lo[channel], v)
                hi[channel] = max(hi[channel], v)
            }
        }
        var best = 0, bestRange = -1.0
        for channel in 0..<3 where hi[channel] - lo[channel] > bestRange {
            best = channel
            bestRange = hi[channel] - lo[channel]
        }
        return (best, bestRange)
    }

    @inline(__always)
    private static func component(_ c: RGBAColor, _ channel: Int) -> Double {
        channel == 0 ? c.red : (channel == 1 ? c.green : c.blue)
    }
}
