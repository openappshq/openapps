import Foundation

/// One field sampled on the canonical grid: a tone position per cell
/// (0 the ground, 1 the loudest tone), and what the family knows beyond
/// it — where the residual may dither, a lightness shift for rims, a
/// whole-tone target where the field is a coverage of one tone, and the
/// numbers the quality gate reads.
struct FieldSample {
    let columns: Int
    let rows: Int
    /// Tone position 0…1 per cell.
    var values: [Double]
    /// Where the residual dithers; nil: everywhere.
    var ditherMask: [Bool]?
    /// A lightness shift per cell after coloring, in OKLab L; nil: none.
    var shade: [Double]?
    /// Coverage families: `values` is the coverage of the tone in
    /// `targets` over the ground, dithered between the two.
    var targets: [UInt8]?
    /// Family statistics for the gate (Curation.swift).
    var stats: [String: Double] = [:]

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        values = [Double](repeating: 0, count: columns * rows)
    }
}

/// The canonical grid of a pixel-field document at a display size: the
/// cell, the grid, the whole tone per cell and the sample it came from.
/// Rendered by filling every cell at native size, or area-filtered to a
/// preview, so a thumbnail shows the same structure as the final.
public struct CanonicalField: Sendable {
    public let cell: Int
    public let columns: Int
    public let rows: Int
    /// The tone index per cell, 0…toneSteps − 1.
    public let labels: [UInt8]
    /// The tone position per cell before quantisation.
    public let values: [Double]
    public let steps: Int
    public let stats: [String: Double]
    let shade: [Double]?
}

/// Frame geometry: cells over a native size, positions in units of the
/// height so circles stay circular, the anchor in fractions of width and
/// height.
struct FieldFrame {
    let width: Int, height: Int, cell: Int, columns: Int, rows: Int
    let h: Double

    init(size: PixelSize, cell: Int) {
        width = size.width; height = size.height
        self.cell = max(1, cell)
        columns = (size.width + self.cell - 1) / self.cell
        rows = (size.height + self.cell - 1) / self.cell
        h = Double(size.height)
    }

    /// The center of a cell, in height units.
    @inline(__always)
    func point(_ column: Int, _ row: Int) -> (Double, Double) {
        ((Double(column) + 0.5) * Double(cell) / h, (Double(row) + 0.5) * Double(cell) / h)
    }

    /// An anchor given as fractions of the width and the height.
    func anchor(_ fx: Double, _ fy: Double) -> (Double, Double) {
        (fx * Double(width) / h, fy)
    }

    var aspect: Double { Double(width) / h }
    /// One cell, in height units.
    var cellUnit: Double { Double(cell) / h }
}

/// The residual dither: the fractional tone position of every cell
/// becomes a whole tone through a threshold pattern or error diffusion.
enum ToneDither {
    /// `values` are tone positions 0…1 over `steps` tones. `strength`
    /// scales the diffused error (1: full Floyd–Steinberg).
    static func labels(_ values: [Double], columns: Int, rows: Int, steps: Int, mode: ToneDitherMode, mask: [Bool]?, strength: Double = 1) -> [UInt8] {
        let top = Double(max(1, steps - 1))
        var out = [UInt8](repeating: 0, count: columns * rows)
        switch mode {
        case .none, .bayer, .blueNoise:
            for row in 0..<rows {
                for column in 0..<columns {
                    let i = row * columns + column
                    let s = min(max(values[i], 0), 1) * top
                    let lower = s.rounded(.down)
                    let t = s - lower
                    let dithers = mask?[i] ?? true
                    let threshold: Double
                    switch mode {
                    case .bayer where dithers: threshold = (Double(Ditherer.bayer8[(row & 7) * 8 + (column & 7)]) + 0.5) / 64
                    case .blueNoise where dithers: threshold = BlueNoise.tile[(row % BlueNoise.size) * BlueNoise.size + (column % BlueNoise.size)]
                    default: threshold = 0.5
                    }
                    let level = t > threshold ? lower + 1 : lower
                    out[i] = UInt8(min(top, max(0, level)))
                }
            }
        case .diffusion:
            // Serpentine Floyd–Steinberg on the scalar residual: rows
            // alternate direction and the stencil mirrors with them, so
            // the error never streaks one way.
            var error = [Double](repeating: 0, count: columns * rows)
            let k = min(max(strength, 0), 1)
            for row in 0..<rows {
                let forward = row % 2 == 0
                let columnsInOrder = forward ? Array(0..<columns) : Array((0..<columns).reversed())
                for column in columnsInOrder {
                    let i = row * columns + column
                    let dithers = mask?[i] ?? true
                    let s = min(max(values[i], 0), 1) * top + (dithers ? error[i] : 0)
                    let level = min(top, max(0, s.rounded()))
                    out[i] = UInt8(level)
                    guard dithers else { continue }
                    let e = (s - level) * k
                    let ahead = forward ? 1 : -1
                    func spread(_ dx: Int, _ dy: Int, _ weight: Double) {
                        let x = column + dx, y = row + dy
                        guard x >= 0, x < columns, y < rows else { return }
                        error[y * columns + x] += e * weight
                    }
                    spread(ahead, 0, 7 / 16); spread(-ahead, 1, 3 / 16); spread(0, 1, 5 / 16); spread(ahead, 1, 1 / 16)
                }
            }
        }
        return out
    }
}

/// The sampled-field engine: evaluates a family on the canonical grid,
/// brackets and dithers its tones, colors the cells along the palette
/// (level 0 the base's pixel when a base is set, the lit levels taking
/// `depth` of the base's shading), and writes native pixels — every cell
/// filled at the display size, or the same cells area-filtered into a
/// preview.
public enum FieldEngine {
    /// The canonical grid for a document at a size. `base` is the base
    /// rendered at the grid's size, for the sky's and the plate's
    /// horizonless families it is ignored.
    public static func canonical(_ p: FieldParameters, seed: UInt64, size: PixelSize) -> CanonicalField {
        let frame = FieldFrame(size: size, cell: p.cellSize)
        let sample = evaluate(p, seed: seed, frame: frame)
        let steps = p.toneSteps
        let labels: [UInt8]
        if let targets = sample.targets {
            // Coverage of one tone over the ground: a two-step dither.
            let bits = ToneDither.labels(sample.values, columns: frame.columns, rows: frame.rows, steps: 2, mode: p.ditherMode, mask: sample.ditherMask)
            labels = bits.enumerated().map { $0.element == 0 ? 0 : targets[$0.offset] }
        } else {
            labels = ToneDither.labels(sample.values, columns: frame.columns, rows: frame.rows, steps: steps, mode: p.ditherMode, mask: sample.ditherMask, strength: p.family == .sky ? p[.diffusion] : 1)
        }
        return CanonicalField(cell: frame.cell, columns: frame.columns, rows: frame.rows, labels: labels, values: sample.values, steps: steps, stats: sample.stats, shade: sample.shade)
    }

    /// The document's pixels at `target`, from the canonical grid of
    /// `size` (the display's): the same cells, filled or filtered.
    public static func render(_ p: FieldParameters, seed: UInt64, size: PixelSize, target: PixelSize, base: Raster?) -> Raster {
        let field = canonical(p, seed: seed, size: size)
        let colors = cellColors(p, field: field, base: base)
        return CellFill.raster(colors, columns: field.columns, rows: field.rows, cell: field.cell, canonical: size, target: target)
    }

    /// The tone ramp of `steps` flat colors along the palette.
    static func ramp(_ p: FieldParameters) -> [OKLCH] {
        let tones = p.tones
        let steps = p.toneSteps
        return (0..<steps).map { i in
            let t = Double(i) / Double(steps - 1) * Double(tones.count - 1)
            let index = min(tones.count - 2, Int(t.rounded(.down)))
            let f = t - Double(index)
            let color = p.bool(.oklab) ? OKLCH.mix(tones[index], tones[index + 1], amount: f) : tones[index].mixed(with: tones[index + 1], amount: f)
            return OKLCH(color)
        }
    }

    /// One color per cell: the ramp's tone, the base's pixel for the
    /// ground, the base's shading and the rims folded into lightness.
    static func cellColors(_ p: FieldParameters, field: CanonicalField, base: Raster?) -> [CellColor] {
        let ramp = ramp(p)
        let count = field.columns * field.rows
        let usesBase = base != nil && base!.width == field.columns && base!.height == field.rows && p.family != .sky
        let depth = usesBase ? p[.depth] : 0
        var baseL = [Double](repeating: 0, count: usesBase ? count : 0)
        var meanL = 0.0
        if usesBase, let base {
            for i in 0..<count {
                let o = i * 4
                let y = 0.2126 * Generators.linearChannel(base.pixels[o]) + 0.7152 * Generators.linearChannel(base.pixels[o + 1]) + 0.0722 * Generators.linearChannel(base.pixels[o + 2])
                baseL[i] = cbrt(y)
                meanL += baseL[i]
            }
            meanL /= Double(count)
        }
        // The ramp's bytes, once, for the cells with no shift.
        let plain = ramp.map { lch -> CellColor in
            let c = lch.color
            return CellColor(r: RGBAColor.byte(c.red), g: RGBAColor.byte(c.green), b: RGBAColor.byte(c.blue))
        }
        var colors = [CellColor](repeating: plain[0], count: count)
        for i in 0..<count {
            let level = Int(field.labels[i])
            let shift = (field.shade?[i] ?? 0) + (usesBase && level > 0 ? depth * 0.3 * (baseL[i] - meanL) : 0)
            if usesBase, level == 0, let base {
                let o = i * 4
                colors[i] = CellColor(r: base.pixels[o], g: base.pixels[o + 1], b: base.pixels[o + 2])
            } else if abs(shift) > 0.002 {
                var lch = ramp[level]
                lch.l = min(max(lch.l + shift, 0), 1)
                let c = lch.color
                colors[i] = CellColor(r: RGBAColor.byte(c.red), g: RGBAColor.byte(c.green), b: RGBAColor.byte(c.blue))
            } else {
                colors[i] = plain[level]
            }
        }
        return colors
    }

    // MARK: - Families

    static func evaluate(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        switch p.family {
        case .interference: Interference.sample(p, seed: seed, frame: frame)
        case .relief: Relief.sample(p, seed: seed, frame: frame)
        case .islands: Islands.sample(p, seed: seed, frame: frame)
        case .plate: Plate.sample(p, seed: seed, frame: frame)
        case .circuit: Circuit.sample(p, seed: seed, frame: frame)
        case .sky: Sky.sample(p, seed: seed, frame: frame)
        }
    }
}

struct CellColor {
    var r: UInt8, g: UInt8, b: UInt8
}

/// Native output from a cell grid: every cell filled when the target is
/// the canonical size, else each target pixel the area average of the
/// cells under it (a preview integrates the same content).
enum CellFill {
    static func raster(_ colors: [CellColor], columns: Int, rows: Int, cell: Int, canonical: PixelSize, target: PixelSize) -> Raster {
        if target == canonical { return filled(colors, columns: columns, rows: rows, cell: cell, size: canonical) }
        return filtered(colors, columns: columns, rows: rows, cell: cell, canonical: canonical, target: target)
    }

    static func filled(_ colors: [CellColor], columns: Int, rows: Int, cell: Int, size: PixelSize) -> Raster {
        var raster = Raster(size: size)
        let w = size.width, h = size.height
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<rows {
                for column in 0..<columns {
                    let c = colors[row * columns + column]
                    let x0 = column * cell, y0 = row * cell
                    for y in y0..<min(h, y0 + cell) {
                        var o = (y * w + x0) * 4
                        for _ in x0..<min(w, x0 + cell) {
                            out[o] = c.r; out[o + 1] = c.g; out[o + 2] = c.b; out[o + 3] = 255
                            o += 4
                        }
                    }
                }
            }
        }
        return raster
    }

    /// Box filter: each target pixel covers a rect of canonical pixels;
    /// the cells overlapping it are averaged by their overlap.
    static func filtered(_ colors: [CellColor], columns: Int, rows: Int, cell: Int, canonical: PixelSize, target: PixelSize) -> Raster {
        var raster = Raster(size: target)
        let tw = target.width, th = target.height
        let sx = Double(canonical.width) / Double(tw), sy = Double(canonical.height) / Double(th)
        let fc = Double(cell)
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<th {
                let cy0 = Double(y) * sy / fc, cy1 = Double(y + 1) * sy / fc
                let r0 = max(0, Int(cy0.rounded(.down))), r1 = min(rows - 1, Int((cy1 - 1e-9).rounded(.down)))
                for x in 0..<tw {
                    let cx0 = Double(x) * sx / fc, cx1 = Double(x + 1) * sx / fc
                    let c0 = max(0, Int(cx0.rounded(.down))), c1 = min(columns - 1, Int((cx1 - 1e-9).rounded(.down)))
                    var r = 0.0, g = 0.0, b = 0.0, total = 0.0
                    for row in r0...max(r0, r1) {
                        let wy = min(cy1, Double(row + 1)) - max(cy0, Double(row))
                        guard wy > 0 else { continue }
                        for column in c0...max(c0, c1) {
                            let wx = min(cx1, Double(column + 1)) - max(cx0, Double(column))
                            guard wx > 0 else { continue }
                            let weight = wx * wy
                            let c = colors[row * columns + column]
                            r += Double(c.r) * weight; g += Double(c.g) * weight; b += Double(c.b) * weight
                            total += weight
                        }
                    }
                    let o = (y * tw + x) * 4
                    if total > 0 {
                        out[o] = UInt8(min(255, max(0, (r / total).rounded()))); out[o + 1] = UInt8(min(255, max(0, (g / total).rounded()))); out[o + 2] = UInt8(min(255, max(0, (b / total).rounded())))
                    }
                    out[o + 3] = 255
                }
            }
        }
        return raster
    }
}

// MARK: - Interference atlas

enum Interference {
    static func sample(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        var sample = FieldSample(columns: frame.columns, rows: frame.rows)
        var generator = SeededGenerator(seed: seed)
        let phase = generator.nextUnit()
        let (ax, ay) = frame.anchor(p[.anchorX] + (generator.nextUnit() - 0.5) * 0.06, p[.anchorY] + (generator.nextUnit() - 0.5) * 0.06)
        let theta = p[.twist] * .pi / 180
        let cosT = cos(theta), sinT = sin(theta)
        let fr = p[.repeatX], fl = p[.repeatY]
        let reach = p[.reach]
        let offset = p[.offset]
        let balance = p[.balance]
        let reflect = p.bool(.reflect)
        let mode = p.int(.mode)
        let twoPi = 2 * Double.pi
        for row in 0..<frame.rows {
            for column in 0..<frame.columns {
                let (px, py) = frame.point(column, row)
                var x = px - ax, y = py - ay
                if reflect { x = abs(x); y = abs(y) }
                let r = (x * x + y * y).squareRoot()
                let value: Double
                switch mode {
                case 1, 2:
                    // Two lattices (product) or two weaves (sum), the
                    // second twisted and phase-shifted, fading with reach.
                    let u = x * cosT + y * sinT, v = -x * sinT + y * cosT
                    let a: Double, b: Double
                    if mode == 1 {
                        a = cos(twoPi * (fr * x + phase)) * cos(twoPi * (fl * y + phase))
                        b = cos(twoPi * (fr * u + offset)) * cos(twoPi * (fl * v + offset))
                    } else {
                        a = (cos(twoPi * (fr * x + phase)) + cos(twoPi * (fl * y + phase))) / 2
                        b = (cos(twoPi * (fr * u + offset)) + cos(twoPi * (fl * v + offset))) / 2
                    }
                    let fade = exp(-pow(r / (reach * 1.6), 4))
                    value = fade * (0.5 + 0.5 * (a + b) / 2)
                default:
                    // Radial × linear: rings from the anchor beat against
                    // lines along the twist; a crescent envelope keeps one
                    // sweep and leaves the rest quiet.
                    let along = x * cosT + y * sinT
                    let across = -x * sinT + y * cosT
                    let cR = cos(twoPi * (fr * r + phase))
                    let cL = cos(twoPi * (fl * along + offset))
                    let carrier = (1 - balance) * cR * cL + balance * (cR + cL) / 2
                    let band = exp(-pow((r - reach * 0.75) / (reach * 0.5), 2))
                    let side = 0.2 + 0.8 * (0.5 + 0.5 * (r > 1e-6 ? across / r : 0))
                    let envelope = min(1, band * side + 0.35 * exp(-pow(r / (reach * 0.35), 2)))
                    value = envelope * (0.5 + 0.5 * carrier)
                }
                sample.values[row * frame.columns + column] = min(max(value, 0), 1)
            }
        }
        sample.stats["atlas"] = mode == 0 ? 1 : 0
        return sample
    }
}

// MARK: - Contour relief

enum Relief {
    static func sample(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        var sample = FieldSample(columns: frame.columns, rows: frame.rows)
        let columns = frame.columns, rows = frame.rows
        let scale = p[.scale], warp = p[.warp]
        let levels = p.toneSteps
        let (ax, ay) = frame.anchor(p[.anchorX], p[.anchorY])
        let reach = p[.reach], bump = p[.focal] * 0.6
        let theta = p[.angle] * .pi / 180
        let dx = cos(theta), dy = sin(theta)
        let delta = p[.offset] * 1.2 * frame.cellUnit
        let warpSeed = seed &+ 0x51A7, warpSeed2 = seed &+ 0xC0DE
        func height(_ x: Double, _ y: Double) -> Double {
            let wx = warp * (Generators.fbm(x * scale * 0.7 + 13, y * scale * 0.7 + 13, octaves: 2, persistence: 0.5, seed: warpSeed) - 0.5) * 2
            let wy = warp * (Generators.fbm(x * scale * 0.7 + 71, y * scale * 0.7 + 71, octaves: 2, persistence: 0.5, seed: warpSeed2) - 0.5) * 2
            let n = Generators.fbm((x + wx) * scale, (y + wy) * scale, octaves: 3, persistence: 0.5, seed: seed)
            let ddx = x - ax, ddy = y - ay
            return n + bump * exp(-(ddx * ddx + ddy * ddy) / (reach * reach))
        }
        // The unshifted field first, for the range the thresholds span.
        var base = [Double](repeating: 0, count: columns * rows)
        var lo = Double.infinity, hi = -Double.infinity
        for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = frame.point(column, row)
                let h = height(x, y)
                base[row * columns + column] = h
                lo = min(lo, h); hi = max(hi, h)
            }
        }
        let span = max(hi - lo, 1e-6)
        // Terrace j is where the field, sampled j offsets along the light,
        // clears threshold j: each layer sits shifted over the one below.
        var level = [Int](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = frame.point(column, row)
                var count = 0
                for j in 1..<levels {
                    let threshold = Double(j) / Double(levels)
                    let h = j == 0 ? base[row * columns + column] : height(x + Double(j) * delta * dx, y + Double(j) * delta * dy)
                    if (h - lo) / span >= threshold { count += 1 } else { break }
                }
                level[row * columns + column] = count
            }
        }
        // Rims: a cell higher than its neighbour toward the light is lit,
        // a cell lower than its neighbour away from the light is shaded.
        let strength = p[.rim] * (0.03 + p[.relief] * 0.13)
        var shade = [Double](repeating: 0, count: columns * rows)
        let stepX = dx >= 0 ? 1 : -1, stepY = dy >= 0 ? 1 : -1
        let horizontal = abs(dx) >= abs(dy)
        for row in 0..<rows {
            for column in 0..<columns {
                let i = row * columns + column
                let towardX = horizontal ? column - stepX : column, towardY = horizontal ? row : row - stepY
                let awayX = horizontal ? column + stepX : column, awayY = horizontal ? row : row + stepY
                if towardX >= 0, towardX < columns, towardY >= 0, towardY < rows, level[i] > level[towardY * columns + towardX] { shade[i] += strength }
                if awayX >= 0, awayX < columns, awayY >= 0, awayY < rows, level[i] > level[awayY * columns + awayX] { shade[i] -= strength * 0.7 }
                sample.values[i] = Double(level[i]) / Double(levels - 1)
            }
        }
        sample.shade = shade
        sample.stats["terraces"] = Double(Set(level).count)
        return sample
    }
}

// MARK: - Pixel archipelago

enum Islands {
    static func sample(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        var sample = FieldSample(columns: frame.columns, rows: frame.rows)
        let columns = frame.columns, rows = frame.rows
        let scale = p[.scale] * 1.2, warp = p[.warp]
        let sea = p[.seaLevel]
        let levels = p.toneSteps
        let roughness = p[.roughness]
        let shore = max(1, p.int(.shore))
        let (ax, ay) = frame.anchor(p[.anchorX], p[.anchorY])
        let focal = p[.focal]
        var height = [Double](repeating: 0, count: columns * rows)
        var lo = Double.infinity, hi = -Double.infinity
        for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = frame.point(column, row)
                let wx = warp * (Generators.fbm(x * scale * 0.9 + 5, y * scale * 0.9 + 5, octaves: 2, persistence: 0.5, seed: seed &+ 0xA11) - 0.5) * 2
                let wy = warp * (Generators.fbm(x * scale * 0.9 + 37, y * scale * 0.9 + 37, octaves: 2, persistence: 0.5, seed: seed &+ 0xB22) - 0.5) * 2
                let ddx = x - ax, ddy = y - ay
                let h = Generators.fbm((x + wx) * scale, (y + wy) * scale, octaves: 3, persistence: roughness, seed: seed) + focal * exp(-(ddx * ddx + ddy * ddy) / 0.12)
                height[row * columns + column] = h
                lo = min(lo, h); hi = max(hi, h)
            }
        }
        let span = max(hi - lo, 1e-6)
        var land = [Bool](repeating: false, count: columns * rows)
        for i in 0..<(columns * rows) {
            height[i] = (height[i] - lo) / span
            land[i] = height[i] > sea
        }
        // No crumbs: land in components smaller than four cells is sea.
        let components = Components.label(land, columns: columns, rows: rows)
        var crumbCells = 0
        var landCells = 0
        for i in 0..<(columns * rows) where land[i] {
            landCells += 1
            if components.sizes[components.ids[i]] < 4 { land[i] = false; crumbCells += 1 }
        }
        // Distance to the coast, up to the shore width, for the dither mask
        // and the water's shallows.
        var coast = [Int](repeating: shore + 1, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let i = row * columns + column
                var isCoast = false
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let x = column + dx, y = row + dy
                    guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                    if land[y * columns + x] != land[i] { isCoast = true; break }
                }
                if isCoast { coast[i] = 0 }
            }
        }
        for _ in 0..<shore {
            var next = coast
            for row in 0..<rows {
                for column in 0..<columns {
                    let i = row * columns + column
                    guard coast[i] > shore else { continue }
                    var best = coast[i]
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let x = column + dx, y = row + dy
                        guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                        best = min(best, coast[y * columns + x] + 1)
                    }
                    next[i] = best
                }
            }
            coast = next
        }
        var mask = [Bool](repeating: false, count: columns * rows)
        let top = Double(levels - 1)
        for i in 0..<(columns * rows) {
            let near = coast[i] <= shore
            mask[i] = near
            if land[i] {
                let f = min(1, (height[i] - sea) / max(1 - sea, 1e-6))
                // Level 1 at the shore up to the top level inland; the
                // residual dithers only near the coast.
                var position = (1 + f * (top - 1)) / top
                if !near { position = (Double(Int(1 + f * (top - 1) + 0.5)) ) / top }
                sample.values[i] = position
            } else {
                // Shallows: a little of the first land tone near the coast.
                sample.values[i] = near ? (0.55 / top) * (1 - Double(coast[i]) / Double(shore + 1)) : 0
            }
        }
        sample.ditherMask = mask
        let remaining = Components.label(land, columns: columns, rows: rows)
        let landNow = land.filter { $0 }.count
        sample.stats["landShare"] = Double(landNow) / Double(columns * rows)
        sample.stats["largestIslandShare"] = landNow > 0 ? Double(remaining.sizes.dropFirst().max() ?? 0) / Double(landNow) : 0
        sample.stats["islands"] = Double(remaining.sizes.dropFirst().filter { $0 >= columns * rows / 100 }.count)
        sample.stats["crumb"] = landCells > 0 ? Double(crumbCells) / Double(landCells) : 0
        return sample
    }
}

/// Four-connected components of a mask; id 0 is "not in the mask".
enum Components {
    struct Result {
        var ids: [Int]
        /// Cell counts per id; `sizes[0]` counts the cells outside the mask.
        var sizes: [Int]
    }

    static func label(_ mask: [Bool], columns: Int, rows: Int) -> Result {
        var ids = [Int](repeating: 0, count: columns * rows)
        var sizes = [0]
        var stack: [Int] = []
        for start in 0..<(columns * rows) where mask[start] && ids[start] == 0 {
            let id = sizes.count
            sizes.append(0)
            ids[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                sizes[id] += 1
                let column = i % columns, row = i / columns
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let x = column + dx, y = row + dy
                    guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                    let j = y * columns + x
                    if mask[j], ids[j] == 0 { ids[j] = id; stack.append(j) }
                }
            }
        }
        for i in 0..<(columns * rows) where !mask[i] { sizes[0] += 1 }
        return Result(ids: ids, sizes: sizes)
    }
}

// MARK: - Resonance plate

enum Plate {
    static func sample(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        var sample = FieldSample(columns: frame.columns, rows: frame.rows)
        let m = Double(p.int(.modeM)), n = Double(p.int(.modeN))
        let beta = p[.balance], epsilon = p[.nodalWidth]
        let theta = p[.angle] * .pi / 180
        let cosT = cos(theta), sinT = sin(theta)
        let reach = p[.reach]
        let (ax, ay) = frame.anchor(p[.anchorX], p[.anchorY])
        let density = 0.4 + 2 * p[.density]
        var generator = SeededGenerator(seed: seed)
        // The seed turns the plate a little and breathes the aperture.
        let turn = (generator.nextUnit() - 0.5) * 0.12
        let aperture = reach * (0.9 + 0.2 * generator.nextUnit())
        let cosS = cos(turn), sinS = sin(turn)
        var covered = 0
        for row in 0..<frame.rows {
            for column in 0..<frame.columns {
                let (px, py) = frame.point(column, row)
                let x0 = px - ax, y0 = py - ay
                let x1 = x0 * cosT + y0 * sinT, y1 = -x0 * sinT + y0 * cosT
                let x = x1 * cosS + y1 * sinS, y = -x1 * sinS + y1 * cosS
                let u = (x / aperture + 1) / 2, v = (y / aperture + 1) / 2
                let f = cos(m * .pi * u) * cos(n * .pi * v) - beta * cos(n * .pi * u) * cos(m * .pi * v)
                let r = (x * x + y * y).squareRoot()
                let window = Generators.smoothstep(aperture, aperture * 0.7, r)
                let value = min(1, max(0, window * exp(-abs(f) / epsilon) * density))
                if value > 0.3 { covered += 1 }
                sample.values[row * frame.columns + column] = value
            }
        }
        sample.stats["nodalCoverage"] = Double(covered) / Double(frame.columns * frame.rows)
        return sample
    }
}

// MARK: - Woven circuit

enum Circuit {
    static func sample(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        var sample = FieldSample(columns: frame.columns, rows: frame.rows)
        let columns = frame.columns, rows = frame.rows
        let tile = max(2, p.int(.scale))
        let tilesX = (columns + tile - 1) / tile, tilesY = (rows + tile - 1) / tile
        let bias = p[.bias], biasScale = p[.biasScale], loops = p[.loops]
        let ribbon = p[.ribbon]
        let tones = p.toneSteps
        // One rotation per tile: a low-frequency field pulls regions the
        // same way, the hash keeps it lively, and `loops` leans on the
        // checkerboard that closes every arc into a ring.
        var rotation = [Bool](repeating: false, count: tilesX * tilesY)
        var width = [Double](repeating: 1, count: tilesX * tilesY)
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let field = Generators.fbm(Double(tx) / biasScale, Double(ty) / biasScale, octaves: 2, persistence: 0.5, seed: seed)
                let hash = Hash.unit(Int64(tx), Int64(ty), seed &+ 0x7A0C)
                let mixed = bias * field + (1 - bias) * hash
                var turned = mixed > 0.5
                if Hash.unit(Int64(tx), Int64(ty), seed &+ 0x100F) < loops * 0.6 { turned = (tx + ty) % 2 == 0 }
                rotation[ty * tilesX + tx] = turned
                width[ty * tilesX + tx] = 0.6 + 0.8 * Generators.fbm(Double(tx) / (biasScale * 1.7) + 9, Double(ty) / (biasScale * 1.7) + 9, octaves: 2, persistence: 0.5, seed: seed &+ 0x33)
            }
        }
        // Paths: every arc joins two edge midpoints; arcs sharing a
        // midpoint chain into one path. Union-find over the arcs.
        let arcCount = tilesX * tilesY * 2
        var parent = Array(0..<arcCount)
        func find(_ a: Int) -> Int {
            var a = a
            while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }
            return a
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        // Midpoint ids: horizontal edges (between rows) and vertical ones.
        func topEdge(_ tx: Int, _ ty: Int) -> Int { ty * tilesX + tx }
        func leftEdge(_ tx: Int, _ ty: Int) -> Int { (tilesY + 1) * tilesX + ty * (tilesX + 1) + tx }
        var owner = [Int: [Int]]()
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let t = ty * tilesX + tx
                // Arc 0 and arc 1 of the tile; unrotated: (top,left) and (bottom,right); rotated: (top,right) and (bottom,left).
                let turned = rotation[t]
                let arcs: [(Int, [Int])] = turned
                    ? [(t * 2, [topEdge(tx, ty), leftEdge(tx + 1, ty)]), (t * 2 + 1, [topEdge(tx, ty + 1), leftEdge(tx, ty)])]
                    : [(t * 2, [topEdge(tx, ty), leftEdge(tx, ty)]), (t * 2 + 1, [topEdge(tx, ty + 1), leftEdge(tx + 1, ty)])]
                for (arc, edges) in arcs {
                    for edge in edges { owner[edge, default: []].append(arc) }
                }
            }
        }
        for (_, arcs) in owner where arcs.count == 2 { union(arcs[0], arcs[1]) }
        var pathSize = [Int: Int]()
        for arc in 0..<arcCount { pathSize[find(arc), default: 0] += 1 }
        // A closed ring of four arcs around one vertex is the smallest loop.
        var loopArcs = 0, longArcs = 0
        var isRing = [Bool](repeating: false, count: arcCount)
        for arc in 0..<arcCount {
            let size = pathSize[find(arc)] ?? 1
            if size >= 3 { longArcs += 1 }
        }
        for ty in 0..<(tilesY - 1) {
            for tx in 0..<(tilesX - 1) {
                // The four tiles around vertex (tx+1, ty+1) close a ring when
                // rotations alternate like a checkerboard.
                let a = rotation[ty * tilesX + tx], b = rotation[ty * tilesX + tx + 1]
                let c = rotation[(ty + 1) * tilesX + tx], d = rotation[(ty + 1) * tilesX + tx + 1]
                if !a && b && c && !d {
                    for t in [(ty * tilesX + tx) * 2 + 1, (ty * tilesX + tx + 1) * 2 + 1, ((ty + 1) * tilesX + tx) * 2, ((ty + 1) * tilesX + tx + 1) * 2] where !isRing[t] {
                        isRing[t] = true
                        loopArcs += 1
                    }
                }
            }
        }
        // The tone per arc: paths alternate the two inks, rings take the
        // accent when the palette has one.
        var arcTone = [UInt8](repeating: 1, count: arcCount)
        var pathIndex = [Int: Int]()
        for arc in 0..<arcCount {
            let root = find(arc)
            if pathIndex[root] == nil { pathIndex[root] = pathIndex.count }
            let index = pathIndex[root]!
            var tone = tones >= 3 ? UInt8(1 + index % 2) : 1
            if tones >= 4, isRing[arc] { tone = UInt8(tones - 1) }
            arcTone[arc] = tone
        }
        // Coverage per cell: the distance to the tile's two arcs.
        var targets = [UInt8](repeating: 0, count: columns * rows)
        let halfCell = 0.5 / Double(tile)
        var quadrantInk = [Double](repeating: 0, count: 4)
        for row in 0..<rows {
            for column in 0..<columns {
                let tx = column / tile, ty = row / tile
                let t = ty * tilesX + tx
                let lx = (Double(column % tile) + 0.5) / Double(tile), ly = (Double(row % tile) + 0.5) / Double(tile)
                let turned = rotation[t]
                let hw = ribbon * width[t] / 2
                // Arc 0 hugs the top-left corner (or top-right when turned), arc 1 the opposite one.
                let c0: (Double, Double) = turned ? (1, 0) : (0, 0)
                let c1: (Double, Double) = turned ? (0, 1) : (1, 1)
                let d0 = abs(((lx - c0.0) * (lx - c0.0) + (ly - c0.1) * (ly - c0.1)).squareRoot() - 0.5)
                let d1 = abs(((lx - c1.0) * (lx - c1.0) + (ly - c1.1) * (ly - c1.1)).squareRoot() - 0.5)
                let nearest = d0 <= d1 ? 0 : 1
                let d = min(d0, d1)
                let coverage = Generators.smoothstep(hw + halfCell, hw - halfCell, d)
                let i = row * columns + column
                sample.values[i] = coverage
                targets[i] = arcTone[t * 2 + nearest]
                let quadrant = (column * 2 / max(1, columns)) + (row * 2 / max(1, rows)) * 2
                quadrantInk[min(3, quadrant)] += coverage
            }
        }
        sample.targets = targets
        let quadrantCells = Double(columns * rows) / 4
        let shares = quadrantInk.map { $0 / quadrantCells }
        sample.stats["longPathShare"] = Double(longArcs) / Double(max(1, arcCount))
        sample.stats["loopShare"] = Double(loopArcs) / Double(max(1, arcCount))
        sample.stats["densityVariation"] = (shares.max() ?? 0) - (shares.min() ?? 0)
        return sample
    }
}

// MARK: - Memory sky

enum Sky {
    static func sample(_ p: FieldParameters, seed: UInt64, frame: FieldFrame) -> FieldSample {
        var sample = FieldSample(columns: frame.columns, rows: frame.rows)
        let columns = frame.columns, rows = frame.rows
        let horizon = p[.horizon]
        let sunX = p[.sunX] * frame.aspect, sunR = p[.sunRadius]
        let haze = p[.haze], ridge = p[.ridge], clouds = p[.clouds]
        var generator = SeededGenerator(seed: seed)
        let ridgePhase = generator.nextUnit() * 10, ridgePhase2 = generator.nextUnit() * 10
        let sunY = horizon - sunR * 0.35
        // The near ridge sits a little below the far one, both drawn from
        // one-dimensional noise along the width.
        var far = [Double](repeating: 0, count: columns), near = far
        for column in 0..<columns {
            let x = (Double(column) + 0.5) * frame.cellUnit
            far[column] = horizon + ridge * (Generators.fbm(x * 3 + ridgePhase, 0.5, octaves: 3, persistence: 0.5, seed: seed &+ 0x51) - 0.5) * 2
            near[column] = horizon + 0.035 + ridge * 1.4 * (Generators.fbm(x * 2.2 + ridgePhase2, 7.5, octaves: 3, persistence: 0.5, seed: seed &+ 0x52) - 0.5) * 2
        }
        // The land is crisp: the near ridge the darkest tone, the far one
        // the next, neither dithered.
        var mask = [Bool](repeating: true, count: columns * rows)
        let top = Double(max(1, p.toneSteps - 1))
        for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = frame.point(column, row)
                let i = row * columns + column
                if y > near[column] {
                    sample.values[i] = 0
                    mask[i] = false
                    continue
                }
                if y > far[column] {
                    sample.values[i] = 1 / top
                    mask[i] = false
                    continue
                }
                // The sky: darker at the top, warm toward the horizon, a
                // haze band at it, the sun and its glow, sparse clouds.
                let t = min(1, y / max(horizon, 1e-6))
                var value = 0.12 + 0.5 * pow(t, 1.3)
                value += 0.32 * exp(-pow((y - horizon) / haze, 2))
                let dx = x - sunX, dy = y - sunY
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= sunR {
                    value = 1
                } else {
                    value += 0.3 * exp(-(d / sunR - 1) * 2.2)
                }
                if y < horizon - haze * 0.5 {
                    let c = Generators.fbm(x * 4, y * 8, octaves: 3, persistence: 0.5, seed: seed &+ 0xC10)
                    if c > 1 - clouds { value -= 0.14 * min(1, (c - (1 - clouds)) / max(clouds * 0.5, 1e-6)) }
                }
                sample.values[i] = min(max(value, 0), 1)
            }
        }
        sample.ditherMask = mask
        sample.stats["horizon"] = horizon
        return sample
    }
}

extension Ditherer {
    /// The 8×8 Bayer matrix, once.
    static let bayer8: [Int] = bayer(8)
}
