import Foundation

/// A 1024-entry table of a gradient's colors along 0…1, so every pixel is a
/// lookup instead of a stop search.
struct ColorTable {
    static let size = 1024
    let r: [Double], g: [Double], b: [Double]

    init(stops: [ColorStop]) {
        var r = [Double](repeating: 0, count: Self.size)
        var g = r, b = r
        var index = 0
        for i in 0..<Self.size {
            let t = Double(i) / Double(Self.size - 1)
            while index < stops.count - 2, t > stops[index + 1].position { index += 1 }
            let a = stops[index], z = stops[index + 1]
            let span = z.position - a.position
            let f = span <= 0 ? (t >= z.position ? 1.0 : 0.0) : min(max((t - a.position) / span, 0), 1)
            let c = a.color.mixed(with: z.color, amount: f)
            r[i] = c.red; g[i] = c.green; b[i] = c.blue
        }
        self.r = r; self.g = g; self.b = b
    }

    @inline(__always)
    func index(_ t: Double) -> Int {
        Int(min(max(t, 0), 1) * Double(Self.size - 1) + 0.5)
    }
}

@inline(__always)
private func byte(_ v: Double) -> UInt8 {
    UInt8(min(255, max(0, v * 255 + 0.5)))
}

/// Per-pixel software renderers. Each writes straight into a raster's bytes
/// with plain arithmetic, so a seed's pixels are the same on every Mac.
enum Generators {
    // MARK: - Gradient

    static func gradient(_ p: GradientParameters, size: PixelSize) -> Raster {
        let table = ColorTable(stops: p.normalizedStops)
        var raster = Raster(size: size)
        let w = size.width, h = size.height
        let fw = Double(w), fh = Double(h)
        let cx = p.center.x * fw, cy = p.center.y * fh
        let radians = p.angle * .pi / 180
        let dx = cos(radians), dy = sin(radians)
        // Linear: the projection of the rect on the direction, so the first
        // stop touches one corner and the last the opposite one.
        let extent = abs(fw * dx) + abs(fh * dy)
        let mx = fw / 2, my = fh / 2
        // Radial: the far corner is the last stop.
        let farX = max(cx, fw - cx), farY = max(cy, fh - cy)
        let radius = max(1, (farX * farX + farY * farY).squareRoot())
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let py = Double(y) + 0.5
                for x in 0..<w {
                    let px = Double(x) + 0.5
                    let t: Double
                    switch p.kind {
                    case .linear:
                        t = extent <= 0 ? 0 : 0.5 + ((px - mx) * dx + (py - my) * dy) / extent
                    case .radial:
                        let ddx = px - cx, ddy = py - cy
                        t = (ddx * ddx + ddy * ddy).squareRoot() / radius
                    case .conic:
                        var a = atan2(py - cy, px - cx) - radians
                        a = a.truncatingRemainder(dividingBy: 2 * .pi)
                        if a < 0 { a += 2 * .pi }
                        t = a / (2 * .pi)
                    }
                    let i = table.index(t)
                    let o = (y * w + x) * 4
                    out[o] = byte(table.r[i]); out[o + 1] = byte(table.g[i]); out[o + 2] = byte(table.b[i]); out[o + 3] = 255
                }
            }
        }
        return raster
    }

    // MARK: - Mesh

    struct ControlPoint {
        var x: Double, y: Double
        var r: Double, g: Double, b: Double
    }

    /// The seed places one point per grid cell (jittered) and walks the
    /// palette in a seeded order, so neighbours differ.
    static func meshPoints(_ p: MeshParameters, seed: UInt64) -> [ControlPoint] {
        var generator = SeededGenerator(seed: seed)
        let order = p.colors.shuffled(using: &generator)
        var points: [ControlPoint] = []
        var index = 0
        for row in 0..<p.rows {
            for column in 0..<p.columns {
                let cellW = 1.0 / Double(p.columns), cellH = 1.0 / Double(p.rows)
                let jx = (generator.nextUnit() - 0.5) * p.jitter * cellW
                let jy = (generator.nextUnit() - 0.5) * p.jitter * cellH
                let color = order[index % order.count]
                index += 1
                points.append(ControlPoint(x: (Double(column) + 0.5) * cellW + jx, y: (Double(row) + 0.5) * cellH + jy, r: color.red, g: color.green, b: color.blue))
            }
        }
        return points
    }

    /// Inverse-distance blend of the control points, computed at most 640
    /// pixels wide and resampled up: a mesh has no detail finer than that,
    /// and the display's 6 megapixels would only cost time.
    static func mesh(_ p: MeshParameters, seed: UInt64, size: PixelSize) -> Raster {
        let points = meshPoints(p, seed: seed)
        let small = size.fitting(width: 640)
        var raster = Raster(size: small)
        let w = small.width, h = small.height
        let aspect = Double(h) / Double(w)
        // Softness widens each point's reach: the epsilon added to the
        // squared distance before the inverse square.
        let eps = 0.002 + p.softness * p.softness * 0.25
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let py = (Double(y) + 0.5) / Double(h) * aspect
                for x in 0..<w {
                    let px = (Double(x) + 0.5) / Double(w)
                    var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
                    for point in points {
                        let dx = px - point.x, dy = py - point.y * aspect
                        let d = dx * dx + dy * dy + eps
                        let weight = 1 / (d * d)
                        sr += point.r * weight; sg += point.g * weight; sb += point.b * weight; sw += weight
                    }
                    let o = (y * w + x) * 4
                    out[o] = byte(sr / sw); out[o + 1] = byte(sg / sw); out[o + 2] = byte(sb / sw); out[o + 3] = 255
                }
            }
        }
        return raster.resampled(to: size)
    }

    // MARK: - Pattern

    static func pattern(_ p: PatternParameters, seed: UInt64, size: PixelSize) -> Raster {
        var raster = Raster(size: size, fill: p.background)
        let w = size.width, h = size.height
        let fg = p.foreground, bg = p.background
        let scale = max(2, p.scale)
        let radians = p.angle * .pi / 180
        let cosA = cos(radians), sinA = sin(radians)
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let py = Double(y) + 0.5
                for x in 0..<w {
                    let px = Double(x) + 0.5
                    // Rotated coordinates for the oriented patterns.
                    let u = px * cosA + py * sinA
                    let v = -px * sinA + py * cosA
                    let coverage: Double
                    switch p.kind {
                    case .dots:
                        let cx = (px / scale).rounded(.down) * scale + scale / 2
                        let cy = (py / scale).rounded(.down) * scale + scale / 2
                        let d = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
                        coverage = smoothstep(scale * 0.28 + 0.75, scale * 0.28 - 0.75, d)
                    case .lines:
                        let m = u.truncatingRemainder(dividingBy: scale)
                        let inLine = m < 0 ? m + scale : m
                        let half = scale * 0.5
                        // A stripe of half the repeat, its two edges anti-aliased.
                        coverage = min(smoothstep(-0.75, 0.75, inLine), smoothstep(half + 0.75, half - 0.75, inLine))
                    case .checks:
                        let cu = Int((u / scale).rounded(.down)), cv = Int((v / scale).rounded(.down))
                        coverage = (cu + cv) & 1 == 0 ? 0 : 1
                    case .noise:
                        coverage = valueNoise(px / scale, py / scale, seed: seed)
                    }
                    let o = (y * w + x) * 4
                    out[o] = byte(bg.red + (fg.red - bg.red) * coverage)
                    out[o + 1] = byte(bg.green + (fg.green - bg.green) * coverage)
                    out[o + 2] = byte(bg.blue + (fg.blue - bg.blue) * coverage)
                    out[o + 3] = 255
                }
            }
        }
        return raster
    }

    @inline(__always)
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Three octaves of value noise on the position hash, 0…1.
    @inline(__always)
    static func valueNoise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        var sum = 0.0, amplitude = 0.5, frequency = 1.0, total = 0.0
        for octave in 0..<3 {
            sum += lattice(x * frequency, y * frequency, seed: seed &+ UInt64(octave) &* 977) * amplitude
            total += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return sum / total
    }

    @inline(__always)
    private static func lattice(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        let fx = x - x0, fy = y - y0
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let ix = Int64(x0), iy = Int64(y0)
        let a = Hash.unit(ix, iy, seed), b = Hash.unit(ix + 1, iy, seed)
        let c = Hash.unit(ix, iy + 1, seed), d = Hash.unit(ix + 1, iy + 1, seed)
        let top = a + (b - a) * sx
        let bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    // MARK: - Solid

    static func solid(_ p: SolidParameters, size: PixelSize) -> Raster {
        Raster(size: size, fill: p.color)
    }

    // MARK: - Grain

    /// Seeded monochrome film grain: ±`amount` × 25 % per pixel, from the
    /// position hash, so it is the same whichever order the pixels are made in.
    static func applyGrain(_ amount: Double, seed: UInt64, to raster: inout Raster) {
        guard amount > 0 else { return }
        let strength = amount * 0.25
        let w = raster.width, h = raster.height
        let grainSeed = seed ^ 0xA5A5_5A5A_1234_5678
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                for x in 0..<w {
                    let n = (Hash.unit(Int64(x), Int64(y), grainSeed) - 0.5) * 2 * strength
                    let o = (y * w + x) * 4
                    for c in 0..<3 {
                        out[o + c] = byte(Double(out[o + c]) / 255 + n)
                    }
                }
            }
        }
    }
}
