#if DEBUG
import AppKit
import MacPaperCore

/// Renders documents to PNGs and contact sheets, no window, no desktop:
/// `MacPaper --renders <directory> [sheet…]`. Sheets: `taste` (the taste
/// set at three display sizes), `families` (every shuffle family across
/// palettes and seeds, light and dark), `cells` (the moiré at three cell
/// sizes and five palettes), `shuffle` (curated Shuffle from a seed, with
/// the gate's verdicts), `bench` (one uncached 5K render, timed). The
/// default is every sheet. Debug builds only.
enum RenderHarness {
    static let renderer = WallpaperRenderer()
    /// A 14" MacBook Pro, a 27" 5K and a 1080p external.
    static let displays: [(String, RenderContext)] = [
        ("14in", RenderContext(size: PixelSize(width: 3024, height: 1964), notch: .virtual, menuBarStrip: 64)),
        ("5k", RenderContext(size: PixelSize(width: 5120, height: 2880), menuBarStrip: 48)),
        ("1080p", RenderContext(size: PixelSize(width: 1920, height: 1080), menuBarStrip: 24)),
    ]

    static func run(directory: URL, sheets: [String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("RENDERS_FAILED \(error)")
            return false
        }
        let wanted = sheets.isEmpty ? ["taste", "families", "cells", "shuffle", "bench"] : sheets
        var ok = true
        for sheet in wanted {
            let started = Date()
            switch sheet {
            case "taste": ok = taste(into: directory) && ok
            case "families": ok = families(into: directory) && ok
            case "cells": ok = cells(into: directory) && ok
            case "shuffle": ok = shuffle(into: directory) && ok
            case "bench": ok = bench(into: directory) && ok
            case "dither": ok = dither(into: directory) && ok
            case "pick": ok = pick(into: directory) && ok
            default: print("RENDERS_UNKNOWN \(sheet)")
            }
            print("RENDERS_SHEET \(sheet) \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        print("RENDERS_DONE \(directory.path)")
        return ok
    }

    // MARK: - Sheets

    /// The taste set: every recipe as a 480-px tile on the 14", plus the
    /// three display sizes of every fourth one at 640 px, and the gate's
    /// verdict in the label.
    static func taste(into directory: URL) -> Bool {
        var tiles: [Tile] = []
        for (index, recipe) in TasteSet.recipes.enumerated() {
            let context = displays[0].1
            let verdict = QualityGate.assess(recipe.wallpaper, renderer: renderer, context: context)
            let light = render(recipe.wallpaper, side: .light, context: context, width: 480)
            tiles.append(Tile(image: light, label: "\(index + 1). \(recipe.name)\(verdict.passes ? "" : " ✗ \(verdict.failures.map(\.rawValue).joined(separator: ","))")"))
            if index % 4 == 0 {
                for (name, other) in displays.dropFirst() {
                    tiles.append(Tile(image: render(recipe.wallpaper, side: .light, context: other, width: 480), label: "   \(name)"))
                }
                tiles.append(Tile(image: render(recipe.wallpaper, side: .dark, context: context, width: 480), label: "   dark"))
            }
        }
        return sheet(tiles, columns: 5, tileWidth: 480, to: directory.appendingPathComponent("taste-sheet.png"))
    }

    /// Every family: four palettes × six seeds, light, with the verdict.
    static func families(into directory: URL) -> Bool {
        var ok = true
        let palettes = ["Mint Circuit", "Neon Night", "Blueprint", "Magma", "Paper White", "Vaporwave", "Rust", "Sea"].compactMap(Palettes.preset(named:))
        for family in RecipeFamily.all where family.kind != .pixelize {
            var tiles: [Tile] = []
            for (pi, palette) in palettes.enumerated() {
                for seed in 1...4 {
                    var generator = SeededGenerator(seed: UInt64(pi * 100 + seed))
                    var wallpaper = family.draw(palette, &generator)
                    wallpaper.seed = UInt64(pi * 100 + seed)
                    let context = displays[0].1
                    let verdict = QualityGate.assess(wallpaper, renderer: renderer, context: context)
                    let image = render(wallpaper, side: .light, context: context, width: 360)
                    let metrics = ["energy", "range56", "quiet", "mud"].compactMap { key in verdict.metrics[key].map { "\(key.prefix(2)) \(String(format: "%.2f", $0))" } }.joined(separator: " ")
                    tiles.append(Tile(image: image, label: "\(palette.name) #\(pi * 100 + seed)\(verdict.passes ? "" : " ✗ " + verdict.failures.map(\.rawValue).joined(separator: ",")) · \(metrics)"))
                }
            }
            let name = family.name.lowercased().replacingOccurrences(of: " ", with: "-")
            ok = sheet(tiles, columns: 4, tileWidth: 360, to: directory.appendingPathComponent("family-\(name).png")) && ok
        }
        return ok
    }

    /// The moiré at three cell sizes and five palettes, 14" and 5K crops
    /// at native pixels.
    static func cells(into directory: URL) -> Bool {
        var tiles: [Tile] = []
        let palettes = ["Mint Circuit", "Neon Night", "Blueprint", "Magma", "Paper White"].compactMap(Palettes.preset(named:))
        for palette in palettes {
            for cell in [8, 12, 20] {
                var generator = SeededGenerator(seed: 7)
                var wallpaper = RecipeFamily.named("Moiré atlas")!.draw(palette, &generator)
                if case .field(var p) = wallpaper.generator { p[.cellSize] = Double(cell); wallpaper.generator = .field(p) }
                let context = displays[0].1
                let full = renderer.render(wallpaper, side: .light, context: context)
                // A 480×300 crop at native pixels from the middle.
                tiles.append(Tile(image: crop(full, width: 480, height: 300), label: "\(palette.name) cell \(cell) · native crop"))
                tiles.append(Tile(image: full.cgImage.map { downscale($0, width: 480) } ?? crop(full, width: 480, height: 300), label: "   whole"))
            }
        }
        return sheet(tiles, columns: 6, tileWidth: 480, to: directory.appendingPathComponent("cells-sheet.png"))
    }

    /// Curated Shuffle from a fixed seed: 24 consecutive draws, each from
    /// the previous, with the verdict.
    static func shuffle(into directory: URL) -> Bool {
        var tiles: [Tile] = []
        var generator = SeededGenerator(seed: 2026)
        var previous: Wallpaper? = nil
        let context = displays[0].1
        for i in 0..<24 {
            let next = Shuffle.next(from: previous, using: &generator, renderer: renderer, context: context)
            let verdict = QualityGate.assess(next, renderer: renderer, context: context, previous: previous)
            tiles.append(Tile(image: render(next, side: .light, context: context, width: 360), label: "\(i + 1). \(Recipe.defaultName(for: next))\(verdict.passes ? "" : " ✗ " + verdict.failures.map(\.rawValue).joined(separator: ","))"))
            previous = next
        }
        return sheet(tiles, columns: 6, tileWidth: 360, to: directory.appendingPathComponent("shuffle-sheet.png"))
    }

    /// Every dither mode over a gradient and a mesh base, two colors and a
    /// palette, at preview scale and as a native crop.
    static func dither(into directory: URL) -> Bool {
        var tiles: [Tile] = []
        let palette = Palettes.preset(named: "Magma")!
        var g = SeededGenerator(seed: 3)
        let bases: [(String, BaseLayer)] = [("gradient", Draw.tonalBase(palette, using: &g)), ("mesh", .mesh(MeshParameters(columns: 3, rows: 2, colors: [palette.ground, palette.tones[3], palette.tones[1], palette.ground], jitter: 0.5, softness: 0.6)))]
        let context = displays[0].1
        for (baseName, base) in bases {
            for mode in DitherMode.allCases {
                for paletteSize in [nil, 5] as [Int?] {
                    let cell = mode.isGlyphMode ? 14 : 3
                    let p = DitherParameters(source: nil, mode: mode, cell: cell, paletteSize: paletteSize, ink: palette.tones[3], paper: palette.ground, fit: .stretch)
                    let wallpaper = Wallpaper(generator: .dither(p), seed: 3, grain: 0.03, base: base)
                    let verdict = QualityGate.assess(wallpaper, renderer: renderer, context: context)
                    tiles.append(Tile(image: render(wallpaper, side: .light, context: context, width: 360), label: "\(baseName) \(mode.rawValue) \(paletteSize.map { "p\($0)" } ?? "2c")\(verdict.passes ? "" : " ✗ " + verdict.failures.map(\.rawValue).joined(separator: ","))"))
                    let full = renderer.render(wallpaper, side: .light, context: context)
                    tiles.append(Tile(image: crop(full, width: 360, height: 225), label: "   native crop"))
                }
            }
        }
        return sheet(tiles, columns: 4, tileWidth: 360, to: directory.appendingPathComponent("dither-sheet.png"))
    }

    /// Curation: for every taste-set entry, the first eight seeds from its
    /// own that pass the gate, as tiles, so the seed can be chosen by eye.
    /// Prints `RENDERS_PICK <family> <palette> <seeds…>`.
    static func pick(into directory: URL) -> Bool {
        var ok = true
        let context = displays[0].1
        for (index, entry) in TasteSet.entries.enumerated() {
            guard let family = RecipeFamily.named(entry.family), let palette = Palettes.preset(named: entry.palette) else { continue }
            var tiles: [Tile] = []
            var passing: [UInt64] = []
            var seed = entry.seed
            var tried = 0
            while passing.count < 8, tried < 60 {
                var generator = SeededGenerator(seed: seed)
                var wallpaper = family.draw(palette, &generator)
                wallpaper.seed = seed
                let verdict = QualityGate.assess(wallpaper, renderer: renderer, context: context)
                if verdict.passes {
                    passing.append(seed)
                    tiles.append(Tile(image: render(wallpaper, side: .light, context: context, width: 360), label: "\(entry.palette) · \(entry.family) seed \(seed)"))
                }
                seed += 1000
                tried += 1
            }
            print("RENDERS_PICK \(index + 1) \(entry.family) | \(entry.palette) | \(passing.map(String.init).joined(separator: " "))")
            ok = sheet(tiles, columns: 4, tileWidth: 360, to: directory.appendingPathComponent("pick-\(String(format: "%02d", index + 1)).png")) && ok
        }
        return ok
    }

    /// One uncached 5K render of the first taste recipe, timed, written.
    static func bench(into directory: URL) -> Bool {
        let context = displays[1].1
        for recipe in TasteSet.recipes.prefix(3) {
            let started = Date()
            let raster = renderer.render(recipe.wallpaper, side: .light, context: context)
            let elapsed = Date().timeIntervalSince(started)
            print("RENDERS_BENCH \(recipe.name) 5K \(String(format: "%.2f", elapsed))s \(raster.byteCount / 1_000_000) MB")
        }
        let raster = renderer.render(TasteSet.recipes[0].wallpaper, side: .light, context: context)
        guard let data = raster.pngData() else { return false }
        do {
            try data.write(to: directory.appendingPathComponent("bench-5k.png"))
        } catch {
            print("RENDERS_WRITE_FAILED bench \(error)")
            return false
        }
        return true
    }

    // MARK: - Drawing

    struct Tile {
        let image: CGImage?
        let label: String
    }

    static func render(_ wallpaper: Wallpaper, side: Side, context: RenderContext, width: Int) -> CGImage? {
        let scale = Double(width) / Double(context.size.width)
        return renderer.render(wallpaper, side: side, context: context, scale: scale).cgImage
    }

    static func crop(_ raster: Raster, width: Int, height: Int) -> CGImage? {
        let x0 = max(0, (raster.width - width) / 2), y0 = max(0, (raster.height - height) / 2)
        let w = min(width, raster.width), h = min(height, raster.height)
        var out = Raster(width: w, height: h)
        for y in 0..<h {
            let src = ((y0 + y) * raster.width + x0) * 4
            let dst = y * w * 4
            out.pixels.replaceSubrange(dst..<(dst + w * 4), with: raster.pixels[src..<(src + w * 4)])
        }
        return out.cgImage
    }

    static func downscale(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, image.height * width / image.width)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Tiles in a grid with their labels, on a dark ground.
    static func sheet(_ tiles: [Tile], columns: Int, tileWidth: Int, to url: URL) -> Bool {
        guard !tiles.isEmpty else { return true }
        let tileHeight = tiles.compactMap { $0.image.map { $0.height * tileWidth / $0.width } }.max() ?? tileWidth * 2 / 3
        let labelHeight = 22, gap = 10
        let rows = (tiles.count + columns - 1) / columns
        let width = columns * (tileWidth + gap) + gap
        let height = rows * (tileHeight + labelHeight + gap) + gap
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + column * (tileWidth + gap)
            // Flipped: row 0 at the top.
            let top = height - gap - row * (tileHeight + labelHeight + gap)
            let frame = NSRect(x: x, y: top - tileHeight, width: tileWidth, height: tileHeight)
            if let cg = tile.image {
                let h = cg.height * tileWidth / cg.width
                NSImage(cgImage: cg, size: NSSize(width: tileWidth, height: h)).draw(in: NSRect(x: x, y: top - h, width: tileWidth, height: h))
            } else {
                NSColor.red.setFill()
                frame.fill()
            }
            NSAttributedString(string: tile.label, attributes: attributes).draw(in: NSRect(x: x, y: top - tileHeight - labelHeight, width: tileWidth + gap, height: labelHeight))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print("RENDERS_WROTE \(url.lastPathComponent) \(width)x\(height)")
            return true
        } catch {
            print("RENDERS_WRITE_FAILED \(url.lastPathComponent) \(error)")
            return false
        }
    }
}
#endif
