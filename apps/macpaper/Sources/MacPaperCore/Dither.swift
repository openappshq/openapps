import Foundation

/// The dither lab: an imported image placed per its framing, reduced to
/// a grid of one sample per cell, then dithered to two colors (ink on
/// paper) or to a palette taken from the image. Every mode is software and
/// seeded, so the same image, document and size give the same bytes.
public enum Ditherer {
    /// The most samples a grid may hold: a cell that would exceed it is
    /// coarsened (cell 1 on a 5K display is cell 3), so the sample and
    /// error arrays stay under ~200 MB however large the display.
    public static let maxSamples = 2_500_000

    /// The cell actually used for a size: the document's, widened until the
    /// grid fits the budget.
    public static func effectiveCell(_ cell: Int, for size: PixelSize) -> Int {
        let wanted = max(1, cell)
        let pixels = Double(size.width) * Double(size.height)
        let needed = Int((pixels / Double(maxSamples)).squareRoot().rounded(.up))
        return max(wanted, needed)
    }

    public static func render(_ p: DitherParameters, source: Raster?, seed: UInt64, size: PixelSize) -> Raster {
        guard let source else { return Raster(size: size, fill: p.background) }
        let cell = effectiveCell(p.cell, for: size)
        if p.mode.isGlyphMode {
            return glyphs(p, source: source, size: size, cell: cell)
        }
        let columns = (size.width + cell - 1) / cell
        let rows = (size.height + cell - 1) / cell
        let placement = Pixelizer.Placement(source: source.size, target: size, fit: p.fit, focus: p.focus)
        let samples = Pixelizer.blockAverages(source: source, placement: placement, block: cell, columns: columns, rows: rows, background: p.background)
        let quantised: [RGBAColor]
        if let count = p.paletteSize {
            let palette = MedianCut.palette(of: samples, count: count)
            quantised = dither(samples, columns: columns, rows: rows, mode: p.mode, seed: seed) { color, offset in
                MedianCut.nearest(to: RGBAColor(red: color.red + offset, green: color.green + offset, blue: color.blue + offset), in: palette)
            }
        } else {
            let ink = p.ink, paper = p.paper
            quantised = dither(samples, columns: columns, rows: rows, mode: p.mode, seed: seed, twoTone: (ink, paper)) { color, offset in
                color.luminanceLinearish + offset < 0.5 ? ink : paper
            }
        }
        return fill(quantised, columns: columns, rows: rows, cell: cell, size: size)
    }

    // MARK: - Point dithers

    /// Applies the mode over the grid. `quantise` maps a sample plus a
    /// threshold offset (−0.5…0.5, the ordered patterns) to a color; the
    /// error-diffusing mode passes offset 0 and diffuses what remains —
    /// per channel for a palette, on the luma alone for ink on paper
    /// (`twoTone`), so an ink lighter than its paper still dithers.
    private static func dither(_ samples: [RGBAColor], columns: Int, rows: Int, mode: DitherMode, seed: UInt64, twoTone: (RGBAColor, RGBAColor)? = nil, quantise: (RGBAColor, Double) -> RGBAColor) -> [RGBAColor] {
        switch mode {
        case .bayer2, .bayer4, .bayer8:
            let n = mode == .bayer2 ? 2 : (mode == .bayer4 ? 4 : 8)
            let matrix = bayer(n)
            let scale = 1.0 / Double(n * n)
            var out = samples
            for row in 0..<rows {
                for column in 0..<columns {
                    let threshold = (Double(matrix[(row % n) * n + (column % n)]) + 0.5) * scale - 0.5
                    out[row * columns + column] = quantise(samples[row * columns + column], threshold)
                }
            }
            return out
        case .blueNoise:
            let tile = BlueNoise.tile
            var out = samples
            for row in 0..<rows {
                for column in 0..<columns {
                    let threshold = tile[(row % BlueNoise.size) * BlueNoise.size + (column % BlueNoise.size)] - 0.5
                    out[row * columns + column] = quantise(samples[row * columns + column], threshold)
                }
            }
            return out
        case .floydSteinberg:
            // Serpentine: rows alternate direction and the stencil mirrors
            // with them, so the error never streaks one way.
            if let (ink, paper) = twoTone {
                var luma = samples.map(\.luminanceLinearish)
                var out = samples
                for row in 0..<rows {
                    let forward = row % 2 == 0
                    let ahead = forward ? 1 : -1
                    for step in 0..<columns {
                        let column = forward ? step : columns - 1 - step
                        let i = row * columns + column
                        let value = min(max(luma[i], 0), 1)
                        let dark = value < 0.5
                        out[i] = dark ? ink : paper
                        let e = value - (dark ? 0 : 1)
                        func spread(_ dx: Int, _ dy: Int, _ weight: Double) {
                            let x = column + dx, y = row + dy
                            guard x >= 0, x < columns, y < rows else { return }
                            luma[y * columns + x] += e * weight
                        }
                        spread(ahead, 0, 7 / 16); spread(-ahead, 1, 3 / 16); spread(0, 1, 5 / 16); spread(ahead, 1, 1 / 16)
                    }
                }
                return out
            }
            var r = samples.map(\.red), g = samples.map(\.green), b = samples.map(\.blue)
            var out = samples
            for row in 0..<rows {
                let forward = row % 2 == 0
                let ahead = forward ? 1 : -1
                for step in 0..<columns {
                    let column = forward ? step : columns - 1 - step
                    let i = row * columns + column
                    let color = RGBAColor(red: min(max(r[i], 0), 1), green: min(max(g[i], 0), 1), blue: min(max(b[i], 0), 1))
                    let chosen = quantise(color, 0)
                    out[i] = chosen
                    // The error is bounded: a palette that cannot reach a
                    // color must not push its neighbours off the scale.
                    let er = min(max(color.red - chosen.red, -0.5), 0.5), eg = min(max(color.green - chosen.green, -0.5), 0.5), eb = min(max(color.blue - chosen.blue, -0.5), 0.5)
                    func spread(_ dx: Int, _ dy: Int, _ weight: Double) {
                        let x = column + dx, y = row + dy
                        guard x >= 0, x < columns, y < rows else { return }
                        let j = y * columns + x
                        r[j] += er * weight; g[j] += eg * weight; b[j] += eb * weight
                    }
                    spread(ahead, 0, 7 / 16); spread(-ahead, 1, 3 / 16); spread(0, 1, 5 / 16); spread(ahead, 1, 1 / 16)
                }
            }
            return out
        case .halftone, .ascii:
            return samples
        }
    }

    /// The Bayer matrix of order n (2, 4, 8), values 0..<n².
    static func bayer(_ n: Int) -> [Int] {
        if n == 2 { return [0, 2, 3, 1] }
        let half = bayer(n / 2)
        let h = n / 2
        var out = [Int](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let base = half[(y % h) * h + (x % h)] * 4
                let quadrant = (y / h) * 2 + (x / h)
                out[y * n + x] = base + [0, 2, 3, 1][quadrant]
            }
        }
        return out
    }

    private static func fill(_ colors: [RGBAColor], columns: Int, rows: Int, cell: Int, size: PixelSize) -> Raster {
        var raster = Raster(size: size)
        let w = size.width, h = size.height
        raster.pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<rows {
                for column in 0..<columns {
                    let c = colors[row * columns + column]
                    let r = RGBAColor.byte(c.red), g = RGBAColor.byte(c.green), b = RGBAColor.byte(c.blue)
                    let x0 = column * cell, y0 = row * cell
                    for y in y0..<min(h, y0 + cell) {
                        var o = (y * w + x0) * 4
                        for _ in x0..<min(w, x0 + cell) {
                            out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = 255
                            o += 4
                        }
                    }
                }
            }
        }
        return raster
    }

    // MARK: - Glyph modes

    /// Halftone: a dot of ink per cell on a 45° grid, its area the cell's
    /// darkness. ASCII: one glyph per cell from a ten-step ramp, drawn from
    /// a built-in 5×7 bitmap font (no system font, so no OS dependence).
    private static func glyphs(_ p: DitherParameters, source: Raster, size: PixelSize, cell: Int) -> Raster {
        let w = size.width, h = size.height
        // One luminance sample per cell of the axis-aligned grid, used by
        // both modes; the halftone reads it through the rotated lattice.
        let columns = (w + cell - 1) / cell, rows = (h + cell - 1) / cell
        let placement = Pixelizer.Placement(source: source.size, target: size, fit: p.fit, focus: p.focus)
        let samples = Pixelizer.blockAverages(source: source, placement: placement, block: cell, columns: columns, rows: rows, background: p.background)
        let luminance = samples.map(\.luminanceLinearish)
        var raster = Raster(size: size, fill: p.paper)
        let ink = p.ink
        let ir = RGBAColor.byte(ink.red), ig = RGBAColor.byte(ink.green), ib = RGBAColor.byte(ink.blue)
        let pr = RGBAColor.byte(p.paper.red), pg = RGBAColor.byte(p.paper.green), pb = RGBAColor.byte(p.paper.blue)
        func lum(at x: Double, _ y: Double) -> Double {
            let column = min(columns - 1, max(0, Int(x / Double(cell)))), row = min(rows - 1, max(0, Int(y / Double(cell))))
            return luminance[row * columns + column]
        }
        raster.pixels.withUnsafeMutableBufferPointer { out in
            switch p.mode {
            case .halftone:
                let s = Double(cell)
                let cosA = cos(Double.pi / 4), sinA = sin(Double.pi / 4)
                for y in 0..<h {
                    let py = Double(y) + 0.5
                    for x in 0..<w {
                        let px = Double(x) + 0.5
                        // The rotated lattice cell this pixel falls in, and its center back in pixel space.
                        let u = px * cosA + py * sinA, v = -px * sinA + py * cosA
                        let cu = (u / s).rounded(.down) * s + s / 2, cv = (v / s).rounded(.down) * s + s / 2
                        let cx = cu * cosA - cv * sinA, cy = cu * sinA + cv * cosA
                        let darkness = 1 - lum(at: cx, cy)
                        // A dot whose area is the darkness of the cell, capped so full ink still tiles.
                        let radius = s * 0.5 * 1.15 * darkness.squareRoot()
                        let d = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
                        let coverage = Generators.smoothstep(radius + 0.7, radius - 0.7, d)
                        let o = (y * w + x) * 4
                        out[o] = mixByte(pr, ir, coverage); out[o + 1] = mixByte(pg, ig, coverage); out[o + 2] = mixByte(pb, ib, coverage)
                    }
                }
            case .ascii:
                // Glyph cells are `cell` wide and 7/5 as tall, so the letters keep their shape.
                let glyphW = cell, glyphH = max(1, Int((Double(cell) * 1.4).rounded()))
                let gridColumns = (w + glyphW - 1) / glyphW, gridRows = (h + glyphH - 1) / glyphH
                for gy in 0..<gridRows {
                    for gx in 0..<gridColumns {
                        let x0 = gx * glyphW, y0 = gy * glyphH
                        let darkness = 1 - lum(at: Double(x0) + Double(glyphW) / 2, Double(y0) + Double(glyphH) / 2)
                        let glyph = ASCIIFont.glyph(forDarkness: darkness)
                        for y in y0..<min(h, y0 + glyphH) {
                            let row = min(6, (y - y0) * 7 / glyphH)
                            for x in x0..<min(w, x0 + glyphW) {
                                let column = min(4, (x - x0) * 5 / glyphW)
                                guard glyph[row * 5 + column] else { continue }
                                let o = (y * w + x) * 4
                                out[o] = ir; out[o + 1] = ig; out[o + 2] = ib
                            }
                        }
                    }
                }
            default:
                break
            }
        }
        return raster
    }

    @inline(__always)
    private static func mixByte(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
        UInt8(min(255, max(0, Double(a) + (Double(b) - Double(a)) * t + 0.5)))
    }
}

private extension RGBAColor {
    /// Rec. 601 luma, the quick one the dithers threshold on.
    var luminanceLinearish: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
}

/// A 64×64 blue-noise threshold tile by void-and-cluster (Ulichney), built
/// once from a fixed seed. Values 0…1, each rank used once.
enum BlueNoise {
    static let size = 64
    static let tile: [Double] = make()

    private static func make() -> [Double] {
        let n = size, count = n * n
        // The Gaussian the energy field uses, toroidal.
        let sigma = 1.9
        var kernel = [Double](repeating: 0, count: count)
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(min(x, n - x)), dy = Double(min(y, n - y))
                kernel[y * n + x] = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            }
        }
        var energy = [Double](repeating: 0, count: count)
        func add(_ index: Int, _ sign: Double) {
            let ox = index % n, oy = index / n
            for y in 0..<n {
                let ky = ((y - oy) % n + n) % n
                for x in 0..<n {
                    energy[y * n + x] += sign * kernel[ky * n + ((x - ox) % n + n) % n]
                }
            }
        }
        // An initial pattern of one in ten, seeded.
        var generator = SeededGenerator(seed: 0xB1EE_0001)
        var pattern = [Bool](repeating: false, count: count)
        var ones = 0
        while ones < count / 10 {
            let i = Int(generator.next() % UInt64(count))
            if !pattern[i] { pattern[i] = true; ones += 1; add(i, 1) }
        }
        func tightestCluster() -> Int {
            var best = -1, bestValue = -Double.infinity
            for i in 0..<count where pattern[i] && energy[i] > bestValue { best = i; bestValue = energy[i] }
            return best
        }
        func largestVoid() -> Int {
            var best = -1, bestValue = Double.infinity
            for i in 0..<count where !pattern[i] && energy[i] < bestValue { best = i; bestValue = energy[i] }
            return best
        }
        // Relax the initial pattern until moving a point changes nothing.
        for _ in 0..<count {
            let cluster = tightestCluster()
            pattern[cluster] = false; add(cluster, -1)
            let void = largestVoid()
            if void == cluster { pattern[cluster] = true; add(cluster, 1); break }
            pattern[void] = true; add(void, 1)
        }
        var rank = [Int](repeating: 0, count: count)
        // Phase 1: remove clusters from the prototype, ranking downward.
        var working = pattern
        var workingEnergy = energy
        var rankValue = ones - 1
        while rankValue >= 0 {
            var best = -1, bestValue = -Double.infinity
            for i in 0..<count where working[i] && workingEnergy[i] > bestValue { best = i; bestValue = workingEnergy[i] }
            working[best] = false
            rank[best] = rankValue
            let ox = best % n, oy = best / n
            for y in 0..<n { let ky = ((y - oy) % n + n) % n; for x in 0..<n { workingEnergy[y * n + x] -= kernel[ky * n + ((x - ox) % n + n) % n] } }
            rankValue -= 1
        }
        // Phase 2: fill voids of the prototype, ranking upward.
        working = pattern
        workingEnergy = energy
        rankValue = ones
        while rankValue < count {
            var best = -1, bestValue = Double.infinity
            for i in 0..<count where !working[i] && workingEnergy[i] < bestValue { best = i; bestValue = workingEnergy[i] }
            working[best] = true
            rank[best] = rankValue
            let ox = best % n, oy = best / n
            for y in 0..<n { let ky = ((y - oy) % n + n) % n; for x in 0..<n { workingEnergy[y * n + x] += kernel[ky * n + ((x - ox) % n + n) % n] } }
            rankValue += 1
        }
        return rank.map { (Double($0) + 0.5) / Double(count) }
    }
}

/// A ten-glyph 5×7 ramp from empty to solid: ` .:-=+*#%@`.
enum ASCIIFont {
    static let ramp: [[Bool]] = [
        bits("""
        .....
        .....
        .....
        .....
        .....
        .....
        .....
        """),
        bits("""
        .....
        .....
        .....
        .....
        .....
        ..#..
        .....
        """),
        bits("""
        .....
        ..#..
        .....
        .....
        .....
        ..#..
        .....
        """),
        bits("""
        .....
        .....
        .....
        .###.
        .....
        .....
        .....
        """),
        bits("""
        .....
        .....
        .###.
        .....
        .###.
        .....
        .....
        """),
        bits("""
        .....
        ..#..
        ..#..
        #####
        ..#..
        ..#..
        .....
        """),
        bits("""
        .....
        #.#.#
        .###.
        #####
        .###.
        #.#.#
        .....
        """),
        bits("""
        .#.#.
        #####
        .#.#.
        .#.#.
        #####
        .#.#.
        .....
        """),
        bits("""
        ##..#
        ##.#.
        ..#..
        .#...
        #.##.
        #.##.
        .....
        """),
        bits("""
        #####
        #####
        #####
        #####
        #####
        #####
        #####
        """),
    ]

    static func glyph(forDarkness darkness: Double) -> [Bool] {
        let index = Int((min(max(darkness, 0), 1) * Double(ramp.count - 1)).rounded())
        return ramp[index]
    }

    private static func bits(_ art: String) -> [Bool] {
        art.split(separator: "\n").flatMap { $0.map { $0 == "#" } }
    }
}
