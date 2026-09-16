import Foundation

/// Curated Shuffle. Shuffle never draws a document from the whole
/// parameter space: it draws a recipe *family* — an authored look whose
/// parameter bands are known to be good — with a preset palette, applies
/// the pins, and passes the candidate through the quality gate. A
/// candidate the gate refuses is redrawn, a bounded number of times,
/// deterministically from the seed, so a share code still reproduces.
/// Nothing bare ever comes out: no plain gradient, no flat fill.
public enum Shuffle {
    /// How many candidates one draw may cost.
    public static let attempts = 12

    /// What a draw came to: a document the gate passed, or nothing better
    /// than what is shown — the desktop keeps its current wallpaper then,
    /// and the reason says which veto the pins kept running into.
    public enum Outcome: Equatable, Sendable {
        case document(Wallpaper)
        case nothingBetter(reason: String)

        public var document: Wallpaper? {
            if case .document(let wallpaper) = self { return wallpaper }
            return nil
        }
    }

    /// What the panel says when a draw finds nothing better.
    public static let nothingBetterMessage = "Nothing better found — try another palette or unpin something."

    /// The next document after `template` (the draft, or the display's
    /// current document): the family, palette and every parameter drawn
    /// fresh except what the template pins. `renderer` (the app's, so a
    /// pinned photo renders) and `context` (the display) serve the gate.
    /// A candidate the gate refuses is never returned: after `attempts`
    /// refusals the outcome is `.nothingBetter`.
    public static func next(
        from template: Wallpaper?, pins: Set<ParameterKey>? = nil, using generator: inout SeededGenerator,
        families: [RecipeFamily] = RecipeFamily.all, renderer: WallpaperRenderer = WallpaperRenderer(), context: RenderContext = QualityGate.defaultContext
    ) -> Outcome {
        next(from: template, pins: pins, using: &generator, families: families, renderer: renderer, contexts: [context])
    }

    /// The same draw for a document that goes to several displays at
    /// once: a candidate passes only when the gate passes it on every
    /// display's own context (its pixel size, menu-bar strip and notch);
    /// the one repair is tried once for all of them.
    public static func next(
        from template: Wallpaper?, pins: Set<ParameterKey>? = nil, using generator: inout SeededGenerator,
        families: [RecipeFamily] = RecipeFamily.all, renderer: WallpaperRenderer = WallpaperRenderer(), contexts: [RenderContext]
    ) -> Outcome {
        let contexts = contexts.isEmpty ? [QualityGate.defaultContext] : contexts
        let pinned = pins ?? template?.pinned ?? []
        let eligible = eligibleFamilies(families, template: template, pinned: pinned)
        var lastFailures: [GateFailure] = []
        for _ in 0..<attempts {
            var candidate: Wallpaper
            if eligible.isEmpty, let template {
                // A pinned generator no family makes (a gradient, a mesh):
                // the template's own generator, everything else fresh.
                let palette = Palettes.preset(matching: template.generator.colors) ?? Palette.custom(template.generator.colors)
                candidate = Draw.document(template.generator, palette: palette, base: Draw.base(palette, kinds: [.none, .solid, .gradient], using: &generator), finish: Draw.finish(palette, fringe: 0...0, vignette: 0.1...0.25, using: &generator), grain: generator.nextDouble(in: 0.03...0.05), using: &generator)
            } else {
                let family = pick(eligible, using: &generator)
                let palette: Palette
                if pinned.contains(.palette), let template {
                    palette = Palettes.preset(matching: template.generator.colors) ?? Palette.custom(template.generator.colors)
                } else {
                    palette = Palettes.presets[Int(generator.next() % UInt64(Palettes.presets.count))]
                }
                candidate = family.draw(palette, &generator)
            }
            candidate.seed = generator.next()
            if let template { candidate = Pins.apply(pinned, from: template, to: candidate) }
            candidate.pinned = pinned
            var failures = assess(candidate, renderer: renderer, contexts: contexts, previous: template)
            if failures == [.menuBar], !pinned.contains(.topShade) {
                // The one repair: shade the strip and ask again, everywhere.
                candidate.finish.topShade = max(candidate.finish.topShade, 0.6)
                failures = assess(candidate, renderer: renderer, contexts: contexts, previous: template)
            }
            if failures.isEmpty { return .document(candidate) }
            lastFailures = failures
        }
        return .nothingBetter(reason: lastFailures.map(\.rawValue).joined(separator: ", "))
    }

    /// The failures over every context, in order, without repeats; empty
    /// when every display passes.
    static func assess(_ candidate: Wallpaper, renderer: WallpaperRenderer, contexts: [RenderContext], previous: Wallpaper?) -> [GateFailure] {
        var failures: [GateFailure] = []
        for context in contexts {
            for failure in QualityGate.assess(candidate, renderer: renderer, context: context, previous: previous).failures where !failures.contains(failure) {
                failures.append(failure)
            }
        }
        return failures
    }

    /// The families a pinned generator or family, and a document's photo,
    /// leave open: a pinned `.generator` keeps the kind (and the field
    /// family), a pinned `.family` the field family; the photo families
    /// need a photo. Empty when the pinned generator is one no family
    /// makes — the draw then keeps the template's generator.
    static func eligibleFamilies(_ families: [RecipeFamily], template: Wallpaper?, pinned: Set<ParameterKey>) -> [RecipeFamily] {
        let hasPhoto = template?.generator.source != nil
        var eligible = families.filter { $0.kind != .pixelize || hasPhoto }
        guard let template else { return eligible }
        let field: FieldFamily? = { if case .field(let p) = template.generator { return p.family } else { return nil } }()
        if pinned.contains(.generator) {
            eligible = eligible.filter { $0.kind == template.generator.kind && (field == nil || $0.field == field) }
        } else if pinned.contains(.family), let field {
            eligible = eligible.filter { $0.field == field }
        }
        return eligible
    }

    static func pick(_ families: [RecipeFamily], using generator: inout SeededGenerator) -> RecipeFamily {
        let total = families.reduce(0) { $0 + $1.weight }
        var roll = Int(generator.next() % UInt64(max(1, total)))
        for family in families {
            if roll < family.weight { return family }
            roll -= family.weight
        }
        return families[families.count - 1]
    }
}

// MARK: - Pins

/// Carries pinned parameters from one document into another.
public enum Pins {
    public static func apply(_ pinned: Set<ParameterKey>, from template: Wallpaper, to candidate: Wallpaper) -> Wallpaper {
        var out = candidate
        if pinned.contains(.seed) { out.seed = template.seed }
        if pinned.contains(.base) { out.base = template.base }
        if pinned.contains(.composition) { out.composition = template.composition }
        if pinned.contains(.pair) { out.pair = template.pair }
        if pinned.contains(.grain) { out.grain = template.grain }
        if pinned.contains(.topShade) { out.finish.topShade = template.finish.topShade }
        if pinned.contains(.vignette) { out.finish.vignette = template.finish.vignette }
        if pinned.contains(.fringe) { out.finish.fringe = template.finish.fringe }
        if pinned.contains(.wash) { out.finish.wash = template.finish.wash }
        if pinned.contains(.tint) { out.finish.tint = template.finish.tint }
        if pinned.contains(.duotone) { out.finish.duotone = template.finish.duotone }
        if pinned.contains(.gradientMap) { out.finish.gradientMap = template.finish.gradientMap }
        if pinned.contains(.palette) {
            // The template's colors in the candidate's generator and base.
            let colors = Palettes.usable(template.generator.colors)
            out.generator = out.generator.withPalette(colors)
            if !pinned.contains(.base) { out.base = BaseLayer.default(out.base.kind, colors: colors) }
        }
        // A photo is never dropped: a candidate that takes one gets the
        // template's, with its framing.
        out.generator = carrySource(from: template.generator, to: out.generator)
        out.generator = carryKnobs(pinned, from: template.generator, to: out.generator)
        // A dark side edited by hand keeps its own pinned palette, photo
        // and knobs, over the candidate's derived dark side.
        if let dark = template.darkGenerator {
            var side = out.generator.darkened()
            if pinned.contains(.palette) { side = side.withPalette(Palettes.usable(dark.colors)) }
            side = carrySource(from: dark, to: side)
            side = carryKnobs(pinned, from: dark, to: side)
            out.darkGenerator = side == out.generator.darkened() ? nil : side
        }
        return out
    }

    /// The template's photo into a candidate of a photo kind.
    static func carrySource(from template: Generator, to candidate: Generator) -> Generator {
        guard let source = template.source else { return candidate }
        let fit: ImageFit, focus: Point
        switch template {
        case .pixelize(let t): fit = t.fit; focus = t.focus
        case .dither(let t): fit = t.fit; focus = t.focus
        default: fit = .fill; focus = .center
        }
        switch candidate {
        case .pixelize(var c) where c.source == nil:
            c.source = source; c.fit = fit; c.focus = focus
            return .pixelize(c)
        case .dither(var c) where c.source == nil:
            c.source = source; c.fit = fit; c.focus = focus
            return .dither(c)
        default:
            return candidate
        }
    }

    /// The pinned knobs of the template's generator into the candidate's,
    /// where the candidate is of the same kind (a pinned generator makes
    /// it so; otherwise the pins are carried but do nothing this time).
    static func carryKnobs(_ pinned: Set<ParameterKey>, from template: Generator, to candidate: Generator) -> Generator {
        switch (template, candidate) {
        case (.field(let t), .field(var c)):
            if pinned.contains(.family) { c = c.inFamily(t.family) }
            for key in pinned where t.family.spec(key) != nil && c.family.spec(key) != nil { c[key] = t[key] }
            return .field(c)
        case (.pattern(let t), .pattern(var c)):
            if pinned.contains(.patternKind) { c.kind = t.kind }
            if pinned.contains(.scale) { c.scale = t.scale }
            if pinned.contains(.angle) { c.angle = t.angle }
            return .pattern(c)
        case (.mesh(let t), .mesh(var c)):
            // The panel's one Grid pin is `.columns`: it keeps both.
            if pinned.contains(.columns) { c.columns = t.columns; c.rows = t.rows }
            if pinned.contains(.rows) { c.rows = t.rows }
            if pinned.contains(.jitter) { c.jitter = t.jitter }
            if pinned.contains(.softness) { c.softness = t.softness }
            return .mesh(c)
        case (.dither(let t), .dither(var c)):
            if pinned.contains(.ditherMode) { c.mode = t.mode; c.cell = min(max(c.cell, t.mode.cellRange.lowerBound), t.mode.cellRange.upperBound) }
            if pinned.contains(.cell) { c.cell = min(max(t.cell, c.mode.cellRange.lowerBound), c.mode.cellRange.upperBound) }
            if pinned.contains(.paletteSize) { c.paletteSize = t.paletteSize }
            if pinned.contains(.framing) { c.fit = t.fit; c.focus = t.focus }
            return .dither(c)
        case (.pixelize(let t), .pixelize(var c)):
            if pinned.contains(.blockSize) { c.blockSize = t.blockSize }
            if pinned.contains(.paletteSize) { c.paletteSize = t.paletteSize }
            if pinned.contains(.framing) { c.fit = t.fit; c.focus = t.focus }
            return .pixelize(c)
        case (.gradient(let t), .gradient(var c)):
            if pinned.contains(.gradientKind) { c.kind = t.kind }
            if pinned.contains(.angle) { c.angle = t.angle }
            if pinned.contains(.center) { c.center = t.center }
            if pinned.contains(.interpolation) { c.interpolation = t.interpolation }
            return .gradient(c)
        default:
            return candidate
        }
    }
}

// MARK: - Families

/// An authored look: a generator kind (and field family), the parameter
/// bands that look good, a finish stack, and how often Shuffle draws it.
public struct RecipeFamily: Sendable {
    public let name: String
    public let kind: GeneratorKind
    public let field: FieldFamily?
    /// The field's `mode` knob the family draws (the atlas and the
    /// lattice are one field family); nil for any.
    public let fieldMode: Int?
    /// How often Shuffle draws it; 0 keeps it out of Shuffle (a manual
    /// pick that still has a finish stack and gate bands).
    public let weight: Int
    /// The share of quiet patches the gate accepts (composed looks leave
    /// more ground; all-over textiles less).
    public let quiet: ClosedRange<Double>
    /// The least texture energy the gate accepts: lower for the families
    /// made of large flat regions (a contour plate is not a gradient).
    public let textureFloor: Double
    public let draw: @Sendable (Palette, inout SeededGenerator) -> Wallpaper

    public init(name: String, kind: GeneratorKind, field: FieldFamily? = nil, fieldMode: Int? = nil, weight: Int, quiet: ClosedRange<Double>, textureFloor: Double = QualityGate.textureFloor, draw: @escaping @Sendable (Palette, inout SeededGenerator) -> Wallpaper) {
        self.name = name
        self.kind = kind
        self.field = field
        self.fieldMode = fieldMode
        self.weight = weight
        self.quiet = quiet
        self.textureFloor = textureFloor
        self.draw = draw
    }

    /// The families Shuffle draws from: the catalogue's entries with a
    /// weight. Never a bare gradient, never a solid: those are bases.
    public static let all: [RecipeFamily] = catalogue.filter { $0.weight > 0 }

    /// Every authored family, the manual-only ones included (the lattice
    /// moiré, pattern grids and dithered bases read as textiles or as
    /// gradients at a glance, so Shuffle leaves them alone).
    public static let catalogue: [RecipeFamily] = [
        RecipeFamily(name: "Moiré atlas", kind: .field, field: .interference, fieldMode: 0, weight: 3, quiet: 0.1...0.75) { palette, g in
            var p = FieldParameters(family: .interference, tones: Draw.tones(palette, 2...4, using: &g))
            p[.mode] = 0
            p[.repeatX] = g.nextDouble(in: 4...16); p[.repeatY] = g.nextDouble(in: 3...12)
            p[.twist] = g.nextDouble(in: -40...40)
            p[.anchorX] = g.nextDouble(in: 0.15...0.85); p[.anchorY] = g.nextDouble(in: 0.2...0.8)
            p[.reach] = g.nextDouble(in: 0.55...1); p[.balance] = g.nextDouble(in: 0.3...0.7); p[.offset] = g.nextUnit()
            p[.cellSize] = Draw.pick([8, 10, 12, 14, 16, 20, 24], using: &g)
            p[.toneSteps] = Double(min(5, max(3, p.tones.count + Int(g.next() % 2))))
            p[.dither] = Double(g.nextUnit() < 0.8 ? ToneDitherMode.none.rawValue : ToneDitherMode.bayer.rawValue)
            p[.depth] = g.nextDouble(in: 0.2...0.5)
            return Draw.document(.field(p), palette: palette, base: Draw.base(palette, kinds: [.solid, .gradient, .gradient], using: &g), finish: Draw.finish(palette, fringe: 0.2...0.4, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.03...0.05), using: &g)
        },
        RecipeFamily(name: "Moiré lattice", kind: .field, field: .interference, fieldMode: 1, weight: 0, quiet: 0...0.55) { palette, g in
            var p = FieldParameters(family: .interference, tones: Draw.tones(palette, 2...4, using: &g))
            p[.mode] = Double(1 + Int(g.next() % 2))
            p[.repeatX] = g.nextDouble(in: 3...8); p[.repeatY] = g.nextDouble(in: 3...8)
            p[.twist] = g.nextDouble(in: 4...20) * (g.nextUnit() < 0.5 ? -1 : 1)
            p[.anchorX] = g.nextDouble(in: 0.3...0.7); p[.anchorY] = g.nextDouble(in: 0.3...0.7)
            p[.reach] = g.nextDouble(in: 0.7...1); p[.offset] = g.nextUnit()
            p[.reflect] = g.nextUnit() < 0.3 ? 1 : 0
            p[.cellSize] = Draw.pick([8, 10, 12, 16], using: &g)
            p[.toneSteps] = Double(min(5, max(3, p.tones.count + Int(g.next() % 2))))
            p[.dither] = Double(g.nextUnit() < 0.5 ? ToneDitherMode.none.rawValue : ToneDitherMode.bayer.rawValue)
            return Draw.document(.field(p), palette: palette, base: Draw.base(palette, kinds: [.solid, .gradient, .mesh], using: &g), finish: Draw.finish(palette, fringe: 0.2...0.35, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.03...0.05), using: &g)
        },
        RecipeFamily(name: "Contour relief", kind: .field, field: .relief, weight: 2, quiet: 0.1...0.8, textureFloor: 0.0025) { palette, g in
            var p = FieldParameters(family: .relief, tones: Draw.tones(palette, 3...6, using: &g))
            p[.scale] = g.nextDouble(in: 1.2...2.6); p[.warp] = g.nextDouble(in: 0.03...0.12)
            p[.toneSteps] = Double(5 + Int(g.next() % 2))
            p[.offset] = g.nextDouble(in: 0.3...0.8); p[.angle] = Double(Int(g.next() % 8)) * 45
            p[.rim] = g.nextDouble(in: 0.4...0.8); p[.relief] = g.nextDouble(in: 0.3...0.7)
            p[.anchorX] = g.nextDouble(in: 0.3...0.75); p[.anchorY] = g.nextDouble(in: 0.3...0.7)
            p[.reach] = g.nextDouble(in: 0.3...0.7); p[.focal] = g.nextDouble(in: 0.3...0.8)
            p[.cellSize] = Draw.pick([8, 10, 12, 14], using: &g)
            p[.dither] = Double(ToneDitherMode.none.rawValue)
            return Draw.document(.field(p), palette: palette, base: .none, finish: Draw.finish(palette, fringe: 0...0, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.025...0.04), using: &g)
        },
        RecipeFamily(name: "Pixel archipelago", kind: .field, field: .islands, weight: 2, quiet: 0.1...0.8, textureFloor: 0.0025) { palette, g in
            var p = FieldParameters(family: .islands, tones: Draw.tones(palette, 3...5, using: &g))
            p[.scale] = g.nextDouble(in: 1.2...2.8); p[.warp] = g.nextDouble(in: 0.06...0.18)
            p[.seaLevel] = g.nextDouble(in: 0.45...0.62); p[.toneSteps] = Double(4 + Int(g.next() % 2))
            p[.roughness] = g.nextDouble(in: 0.3...0.5); p[.shore] = Double(2 + Int(g.next() % 2))
            p[.focal] = g.nextDouble(in: 0.1...0.3)
            p[.anchorX] = g.nextDouble(in: 0.3...0.7); p[.anchorY] = g.nextDouble(in: 0.3...0.7)
            p[.cellSize] = Draw.pick([8, 10, 12, 16], using: &g)
            p[.dither] = Double(ToneDitherMode.blueNoise.rawValue)
            return Draw.document(.field(p), palette: palette, base: Draw.base(palette, kinds: [.solid, .gradient], using: &g), finish: Draw.finish(palette, fringe: 0...0, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.025...0.04), using: &g)
        },
        RecipeFamily(name: "Resonance plate", kind: .field, field: .plate, weight: 2, quiet: 0.1...0.85) { palette, g in
            var p = FieldParameters(family: .plate, tones: Draw.tones(palette, 2...3, using: &g))
            let modes: [(Double, Double)] = [(2, 3), (3, 5), (2, 5), (3, 4), (4, 7), (3, 7), (5, 7), (2, 7), (4, 5)]
            let (m, n) = modes[Int(g.next() % UInt64(modes.count))]
            p[.modeM] = m; p[.modeN] = n
            p[.balance] = g.nextDouble(in: 0.85...1.15); p[.nodalWidth] = g.nextDouble(in: 0.04...0.1)
            p[.angle] = Draw.pick([0, 0, 45, 22.5, 67.5], using: &g)
            p[.reach] = g.nextDouble(in: 0.45...0.8); p[.density] = g.nextDouble(in: 0.15...0.4)
            p[.toneSteps] = Double(p.tones.count)
            p[.anchorX] = g.nextDouble(in: 0.35...0.65); p[.anchorY] = g.nextDouble(in: 0.35...0.65)
            p[.cellSize] = Draw.pick([6, 8, 10, 12], using: &g)
            p[.dither] = Double(ToneDitherMode.blueNoise.rawValue)
            return Draw.document(.field(p), palette: palette, base: Draw.base(palette, kinds: [.solid, .gradient], using: &g), finish: Draw.finish(palette, fringe: 0...0, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.025...0.04), using: &g)
        },
        RecipeFamily(name: "Woven circuit", kind: .field, field: .circuit, weight: 2, quiet: 0...0.6) { palette, g in
            var p = FieldParameters(family: .circuit, tones: Draw.tones(palette, 2...4, using: &g))
            p[.scale] = Double(24 + Int(g.next() % 33)); p[.ribbon] = g.nextDouble(in: 0.18...0.32)
            p[.bias] = g.nextDouble(in: 0.4...0.8); p[.biasScale] = g.nextDouble(in: 1.5...3.5)
            p[.loops] = g.nextDouble(in: 0...0.25); p[.accent] = g.nextDouble(in: 0.05...0.12)
            p[.toneSteps] = Double(p.tones.count)
            p[.cellSize] = Draw.pick([6, 8, 10, 12], using: &g)
            p[.dither] = Double(g.nextUnit() < 0.7 ? ToneDitherMode.none.rawValue : ToneDitherMode.bayer.rawValue)
            return Draw.document(.field(p), palette: palette, base: Draw.base(palette, kinds: [.solid, .gradient], using: &g), finish: Draw.finish(palette, fringe: 0.15...0.3, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.03...0.05), using: &g)
        },
        RecipeFamily(name: "Memory sky", kind: .field, field: .sky, weight: 2, quiet: 0.05...0.9, textureFloor: 0.0025) { palette, g in
            // The sun is the loudest tone and the land the darkest: a
            // light-ground palette is turned over.
            var tones = Draw.tones(palette, 3...5, using: &g)
            if OKLCH(tones[0]).l > OKLCH(tones[tones.count - 1]).l { tones.reverse() }
            var p = FieldParameters(family: .sky, tones: tones)
            p[.horizon] = g.nextDouble(in: 0.45...0.68); p[.sunX] = g.nextDouble(in: 0.2...0.8)
            p[.sunRadius] = g.nextDouble(in: 0.1...0.24); p[.haze] = g.nextDouble(in: 0.06...0.16)
            p[.ridge] = g.nextDouble(in: 0.02...0.06); p[.clouds] = g.nextDouble(in: 0.06...0.2)
            p[.diffusion] = g.nextDouble(in: 0.7...1); p[.toneSteps] = Double(4 + Int(g.next() % 2))
            p[.cellSize] = Draw.pick([10, 12, 14, 16, 20], using: &g)
            p[.dither] = Double(ToneDitherMode.diffusion.rawValue)
            return Draw.document(.field(p), palette: palette, base: .none, finish: Draw.finish(palette, fringe: 0...0, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.03...0.05), using: &g)
        },
        RecipeFamily(name: "Dithered base", kind: .dither, weight: 0, quiet: 0.0...1) { palette, g in
            // Cells big enough to read as texture from across the room.
            let modes: [DitherMode] = [.bayer8, .bayer8, .blueNoise, .floydSteinberg, .halftone, .halftone, .halftone]
            let mode = modes[Int(g.next() % UInt64(modes.count))]
            let cell = mode == .halftone ? 12 + Int(g.next() % 9) : 5 + Int(g.next() % 4)
            let tones = Draw.tones(palette, 2...4, using: &g)
            // Two tones only: a palette dither of a smooth base comes out
            // smooth. Ink where the base is dark, paper where it is light:
            // the darker of the ground and the loudest tone is the ink.
            let ground = tones[0], loud = tones[tones.count - 1]
            let dark = OKLCH(ground).l <= OKLCH(loud).l
            let p = DitherParameters(source: nil, mode: mode, cell: cell, paletteSize: nil, ink: dark ? ground : loud, paper: dark ? loud : ground, fit: .stretch)
            // The base spans the whole palette: what a dither is of.
            return Draw.document(.dither(p), palette: palette, base: Draw.tonalBase(palette, using: &g), finish: Draw.finish(palette, fringe: mode == .halftone ? 0...0 : 0.1...0.2, vignette: 0...0, using: &g), grain: g.nextDouble(in: 0.02...0.04), using: &g)
        },
        RecipeFamily(name: "Pattern grid", kind: .pattern, weight: 0, quiet: 0.0...0.6) { palette, g in
            let kinds: [PatternKind] = [.dots, .lines, .checks]
            let kind = kinds[Int(g.next() % UInt64(kinds.count))]
            let tones = Draw.tones(palette, 2...3, using: &g)
            let p = PatternParameters(kind: kind, foreground: tones[tones.count - 1], background: tones[0], scale: g.nextDouble(in: 96...220), angle: Draw.pick([0, 0, 45, 90, 30], using: &g))
            return Draw.document(.pattern(p), palette: palette, base: Draw.base(palette, kinds: [.gradient, .mesh], using: &g), finish: Draw.finish(palette, fringe: 0.2...0.4, vignette: 0.1...0.2, using: &g), grain: g.nextDouble(in: 0.03...0.05), using: &g)
        },
        RecipeFamily(name: "Pixelized photo", kind: .pixelize, weight: 2, quiet: 0.0...0.8) { palette, g in
            let p = PixelizeParameters(source: nil, blockSize: 12 + Int(g.next() % 21), paletteSize: g.nextUnit() < 0.5 ? 5 + Int(g.next() % 4) : nil, fit: .fill, background: palette.ground)
            return Draw.document(.pixelize(p), palette: palette, base: .none, finish: Draw.finish(palette, fringe: 0.1...0.3, vignette: 0.1...0.2, using: &g), grain: g.nextDouble(in: 0.03...0.05), using: &g)
        },
    ]

    public static func named(_ name: String) -> RecipeFamily? {
        catalogue.first { $0.name == name }
    }

    /// The family a document belongs to, by generator kind, field family
    /// and the field's mode (the lattice is not the atlas).
    public static func matching(_ wallpaper: Wallpaper) -> RecipeFamily? {
        let field: FieldFamily?
        var mode: Int?
        if case .field(let p) = wallpaper.generator {
            field = p.family
            mode = p.family == .interference ? min(1, p.int(.mode)) : nil
        } else {
            field = nil
        }
        return catalogue.first { $0.kind == wallpaper.generator.kind && $0.field == field && ($0.fieldMode == nil || mode == nil || $0.fieldMode == mode) }
    }
}

/// The draws the families share.
public enum Draw {
    /// `count` tones from the palette, ground first: the palette's own
    /// order, trimmed (never reordered, so the ground stays the ground).
    static func tones(_ palette: Palette, _ range: ClosedRange<Int>, using g: inout SeededGenerator) -> [RGBAColor] {
        let available = palette.tones.count
        let lower = min(range.lowerBound, available)
        let upper = min(range.upperBound, available)
        let count = lower + Int(g.next() % UInt64(max(1, upper - lower + 1)))
        if count >= available { return palette.tones }
        // The ground and the loudest, with the steps between them thinned.
        var picked = [palette.tones[0]]
        let middle = Array(palette.tones[1..<(available - 1)])
        let keep = max(0, count - 2)
        for i in 0..<keep { picked.append(middle[i * middle.count / max(1, keep)]) }
        picked.append(palette.tones[available - 1])
        return picked
    }

    static func pick(_ values: [Double], using g: inout SeededGenerator) -> Double {
        values[Int(g.next() % UInt64(values.count))]
    }

    /// A base of one of `kinds`, from the palette's ground.
    static func base(_ palette: Palette, kinds: [BaseKind], using g: inout SeededGenerator) -> BaseLayer {
        let kind = kinds[Int(g.next() % UInt64(kinds.count))]
        switch kind {
        case .none: return .none
        case .solid: return .solid(palette.ground)
        case .gradient:
            // Ground toward its neighbour, in a seeded direction, kept close
            // to the ground so the texture stays the picture.
            let toward = palette.tones.count > 1 ? palette.tones[1] : .white
            let far = OKLCH.mix(palette.ground, toward, amount: g.nextDouble(in: 0.3...0.55)).snapped
            let kinds: [GradientKind] = [.linear, .linear, .radial]
            let gradientKind = kinds[Int(g.next() % UInt64(kinds.count))]
            return .gradient(GradientParameters(kind: gradientKind, angle: Double(Int(g.next() % 8)) * 45, center: Point(x: g.nextDouble(in: 0.2...0.8), y: g.nextDouble(in: 0.2...0.8)), stops: [ColorStop(position: 0, color: palette.ground), ColorStop(position: 1, color: far)], interpolation: .oklch))
        case .mesh:
            let second = OKLCH.mix(palette.ground, palette.tones.count > 1 ? palette.tones[1] : .white, amount: g.nextDouble(in: 0.35...0.55)).snapped
            let third = OKLCH.mix(palette.ground, palette.tones.count > 2 ? palette.tones[2] : .black, amount: g.nextDouble(in: 0.25...0.45)).snapped
            return .mesh(MeshParameters(columns: 2 + Int(g.next() % 2), rows: 2, colors: [palette.ground, second, third], jitter: g.nextDouble(in: 0.3...0.7), softness: g.nextDouble(in: 0.5...0.8)))
        }
    }

    /// A base that runs the whole palette, ground to the loudest tone,
    /// through the middle: what a dither is a dither of.
    public static func tonalBase(_ palette: Palette, using g: inout SeededGenerator) -> BaseLayer {
        let count = palette.tones.count
        let ground = palette.ground, loud = palette.tones[count - 1]
        if g.nextUnit() < 0.5 {
            let kinds: [GradientKind] = [.linear, .linear, .radial]
            let kind = kinds[Int(g.next() % UInt64(kinds.count))]
            var stops = [ColorStop(position: 0, color: ground), ColorStop(position: 1, color: loud)]
            if count >= 3 { stops.insert(ColorStop(position: g.nextDouble(in: 0.35...0.65), color: palette.tones[count / 2]), at: 1) }
            return .gradient(GradientParameters(kind: kind, angle: Double(Int(g.next() % 8)) * 45, center: Point(x: g.nextDouble(in: 0.2...0.8), y: g.nextDouble(in: 0.2...0.8)), stops: stops, interpolation: .oklch))
        }
        let middle = count >= 3 ? palette.tones[count / 2] : OKLCH.mix(ground, loud, amount: 0.5).snapped
        return .mesh(MeshParameters(columns: 2 + Int(g.next() % 2), rows: 2, colors: [ground, loud, middle, ground], jitter: g.nextDouble(in: 0.3...0.7), softness: g.nextDouble(in: 0.5...0.8)))
    }

    /// The finish stack every family ships with: a weak wash between two
    /// of the palette's tones, a vignette in `vignette` (0 for none: the
    /// pixel families keep their cells exact), a fringe in `fringe`.
    static func finish(_ palette: Palette, fringe: ClosedRange<Double>, vignette: ClosedRange<Double>, using g: inout SeededGenerator) -> Finish {
        let count = palette.tones.count
        let a = palette.tones[min(count - 1, 1)], b = palette.tones[min(count - 1, 2)]
        let wash = Wash(from: a, to: b, angle: Double(Int(g.next() % 8)) * 45, amount: g.nextDouble(in: 0.06...0.14))
        let vignetteAmount = vignette.upperBound > 0 ? g.nextDouble(in: vignette) : 0
        let fringeAmount = fringe.upperBound > 0 ? g.nextDouble(in: fringe) : 0
        return Finish(wash: wash, vignette: vignetteAmount, fringe: fringeAmount)
    }

    static func document(_ generator: Generator, palette: Palette, base: BaseLayer, finish: Finish, grain: Double, using g: inout SeededGenerator) -> Wallpaper {
        Wallpaper(generator: generator, seed: g.next(), grain: grain, finish: finish, base: base)
    }
}

// MARK: - Quality gate

/// Why a candidate is refused.
public enum GateFailure: String, Hashable, Sendable {
    /// A bare gradient or a flat fill as the generator itself.
    case bare
    /// The palette's endpoints too close, or two tones too alike.
    case palette
    /// Near-zero high-frequency energy in the structure before finishes.
    case flat
    /// Too little lightness range at 56 px: no silhouette.
    case range
    /// Most pixels in the grey-brown mid-luminance band.
    case mud
    /// Too little or too much quiet ground for the family.
    case quiet
    /// The family's own topology rule (crumbs, coverage, continuity).
    case topology
    /// The menu-bar strip reads under neither text color.
    case menuBar
    /// Too close to the previous document.
    case sameAsBefore
}

public struct GateVerdict: Sendable {
    public var failures: [GateFailure]
    public var metrics: [String: Double]
    /// 0…100, for ranking candidates that all failed something.
    public var score: Double

    public var passes: Bool { failures.isEmpty }
}

/// Scores a document before it is shown. Structure is judged on the plain
/// render (no grain, no finish) at a 256-pixel proxy of the display;
/// readability on the finished render of both sides.
public enum QualityGate {
    /// A 14" MacBook Pro.
    public static let defaultContext = RenderContext(size: PixelSize(width: 3024, height: 1964), notch: .virtual, menuBarStrip: 64)
    public static let proxyWidth = 256

    public static let textureFloor = 0.006
    public static let rangeFloor = 0.12
    public static let mudCeiling = 0.6
    public static let distanceFloor = 0.08

    public static func assess(_ wallpaper: Wallpaper, renderer: WallpaperRenderer = WallpaperRenderer(), context: RenderContext = defaultContext, previous: Wallpaper? = nil) -> GateVerdict {
        var failures: [GateFailure] = []
        var metrics: [String: Double] = [:]
        var score = 100.0
        let family = RecipeFamily.matching(wallpaper)

        // 1. Nothing bare.
        switch wallpaper.generator {
        case .gradient, .solid: failures.append(.bare); score -= 60
        default: break
        }

        // 3. The structure, plain.
        let scale = Double(proxyWidth) / Double(context.size.width)
        var plain = wallpaper
        plain.grain = 0
        plain.finish = Finish()
        let structure = renderer.render(plain, side: .light, context: context, scale: scale)
        let l = Self.lightness(of: structure)

        // 2. The palette: the document's colors — for a photo generator
        // (pixelize, a dither with a source) the photo's own lightness
        // range, read off the structure, since the document holds only a
        // backdrop.
        let colors = wallpaper.colors
        let separation: Double
        if wallpaper.generator.source != nil {
            separation = Self.percentile(l, 0.95) - Self.percentile(l, 0.05)
        } else {
            let lightness = colors.map { OKLCH($0).l }
            separation = (lightness.max() ?? 0) - (lightness.min() ?? 0)
        }
        metrics["separation"] = separation
        if separation < 0.25 { failures.append(.palette); score -= 20 }
        if case .field(let p) = wallpaper.generator {
            let ls = p.tones.map { OKLCH($0).l }
            for i in 1..<ls.count where abs(ls[i] - ls[i - 1]) < 0.07 { failures.append(.palette); score -= 10; break }
        }

        // Texture: on the structure at cell resolution, where a dither is
        // still pixels and a bare gradient is still nothing.
        let cells = renderer.structure(wallpaper, side: .light, context: context)
        let energy = Self.energy(Self.lightness(of: cells), width: cells.width, height: cells.height)
        metrics["energy"] = energy
        if energy < (family?.textureFloor ?? textureFloor) { failures.append(.flat); score -= 40 }
        let small = Self.reduce(l, width: structure.width, height: structure.height, to: 56)
        let range = Self.percentile(small.values, 0.95) - Self.percentile(small.values, 0.05)
        metrics["range56"] = range
        if range < rangeFloor { failures.append(.range); score -= 25 }
        let mud = Self.mudShare(of: structure)
        metrics["mud"] = mud
        if mud > mudCeiling { failures.append(.mud); score -= 25 }
        // Quiet ground is judged on the 64-px reduction, where a dither's
        // rhythm has averaged out and only real structure varies.
        let coarse = Self.reduce(l, width: structure.width, height: structure.height, to: 64)
        let quiet = Self.quietShare(coarse.values, width: coarse.width, height: coarse.height, patch: 4)
        metrics["quiet"] = quiet
        if let family, !family.quiet.contains(quiet) { failures.append(.quiet); score -= 10 }

        // 4. The family's own rules, from the canonical grid.
        if case .field(let p) = wallpaper.generator {
            let field = FieldEngine.canonical(p, seed: wallpaper.seed, size: context.size)
            for (key, value) in field.stats { metrics[key] = value }
            if Self.topology(p.family, field: field, small: small) != nil {
                failures.append(.topology); score -= 20
            }
        }

        // 5. The menu bar, finished, both sides.
        for side in Side.allCases {
            let finished = renderer.render(wallpaper, side: side, context: context, scale: scale)
            let strip = max(1, Int((Double(context.menuBarStrip) * scale).rounded()))
            let readability = MenuBarReadability.assess(finished, stripHeight: strip, side: side)
            metrics["contrast.\(side.rawValue)"] = max(readability.contrastWithWhite, readability.contrastWithBlack)
            metrics["spread.\(side.rawValue)"] = readability.luminanceSpread
            if !readability.readsEitherText {
                if !failures.contains(.menuBar) { failures.append(.menuBar) }
                score -= 15
            }
            // 6. Visibly different from the previous document.
            if side == .light, let previous, previous.generator.kind == wallpaper.generator.kind, fieldFamily(previous) == fieldFamily(wallpaper) {
                let before = renderer.render(previous, side: .light, context: context, scale: scale)
                let distance = Self.distance(finished, before)
                metrics["distance"] = distance
                if distance < distanceFloor { failures.append(.sameAsBefore); score -= 30 }
            }
        }
        return GateVerdict(failures: failures, metrics: metrics, score: max(0, score))
    }

    static func fieldFamily(_ wallpaper: Wallpaper) -> FieldFamily? {
        if case .field(let p) = wallpaper.generator { return p.family }
        return nil
    }

    /// The family vetoes on the canonical grid; nil when it passes.
    static func topology(_ family: FieldFamily, field: CanonicalField, small: (values: [Double], width: Int, height: Int)) -> String? {
        let cells = Double(field.columns * field.rows)
        switch family {
        case .interference:
            // The atlas: between one and six masses of light against the
            // ground at 56 px. The all-over modes are textiles: no masses rule.
            guard field.stats["atlas"] == 1 else { return nil }
            let median = percentile(small.values, 0.5)
            let mask = small.values.map { $0 > median + 0.02 }
            let components = Components.label(mask, columns: small.width, rows: small.height)
            let major = components.sizes.dropFirst().filter { Double($0) >= Double(small.width * small.height) * 0.04 }.count
            return (1...6).contains(major) ? nil : "masses \(major)"
        case .relief:
            let terraces = field.stats["terraces"] ?? 0
            if terraces < 3 { return "terraces \(terraces)" }
            if crumbCount(field) > 30 { return "crumbs" }
            return nil
        case .islands:
            let land = field.stats["landShare"] ?? 0
            let largest = field.stats["largestIslandShare"] ?? 0
            let islands = field.stats["islands"] ?? 0
            if !(0.2...0.65).contains(land) { return "land \(land)" }
            if largest < 0.45 { return "largest \(largest)" }
            if !(1...5).contains(Int(islands)) { return "islands \(islands)" }
            return nil
        case .plate:
            let coverage = field.stats["nodalCoverage"] ?? 0
            let lit = Double(field.labels.filter { $0 > 0 }.count) / cells
            if !(0.03...0.45).contains(coverage) && !(0.03...0.45).contains(lit) { return "coverage \(coverage)" }
            // A bright central cross — every nodal line through the center —
            // is the plate's cliché; more than a tenth of the lit cells
            // within 0.12 of the height from the center is one.
            if (field.stats["centerShare"] ?? 0) > 0.1 { return "center cross" }
            return nil
        case .circuit:
            if (field.stats["longPathShare"] ?? 0) < 0.6 { return "short paths" }
            if (field.stats["loopShare"] ?? 0) > 0.4 { return "loops" }
            if (field.stats["densityVariation"] ?? 0) < 0.03 { return "even density" }
            return nil
        case .sky:
            let top = Double(max(1, field.steps - 1))
            var bias = 0.0
            for i in 0..<field.labels.count { bias += Double(field.labels[i]) / top - field.values[i] }
            bias /= cells
            if abs(bias) > 0.025 { return "diffusion bias \(bias)" }
            return nil
        }
    }

    /// Components smaller than four cells across every tone.
    static func crumbCount(_ field: CanonicalField) -> Int {
        var count = 0
        for tone in 0..<field.steps {
            let mask = field.labels.map { Int($0) == tone }
            let components = Components.label(mask, columns: field.columns, rows: field.rows)
            count += components.sizes.dropFirst().filter { $0 < 4 }.count
        }
        return count
    }

    // MARK: Metrics

    /// OKLab-ish lightness per pixel: the cube root of relative luminance.
    static func lightness(of raster: Raster) -> [Double] {
        var out = [Double](repeating: 0, count: raster.width * raster.height)
        for i in 0..<out.count {
            let o = i * 4
            let y = 0.2126 * Generators.linearChannel(raster.pixels[o]) + 0.7152 * Generators.linearChannel(raster.pixels[o + 1]) + 0.0722 * Generators.linearChannel(raster.pixels[o + 2])
            out[i] = cbrt(y)
        }
        return out
    }

    /// Mean absolute lightness step between neighbours, horizontal and vertical.
    static func energy(_ l: [Double], width: Int, height: Int) -> Double {
        var sum = 0.0, n = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if x + 1 < width { sum += abs(l[i] - l[i + 1]); n += 1 }
                if y + 1 < height { sum += abs(l[i] - l[i + width]); n += 1 }
            }
        }
        return n > 0 ? sum / n : 0
    }

    /// Area-averaged reduction to `target` pixels wide.
    static func reduce(_ l: [Double], width: Int, height: Int, to target: Int) -> (values: [Double], width: Int, height: Int) {
        let tw = max(1, min(target, width))
        let th = max(1, Int((Double(height) * Double(tw) / Double(width)).rounded()))
        var out = [Double](repeating: 0, count: tw * th)
        for y in 0..<th {
            let y0 = y * height / th, y1 = max(y0 + 1, (y + 1) * height / th)
            for x in 0..<tw {
                let x0 = x * width / tw, x1 = max(x0 + 1, (x + 1) * width / tw)
                var sum = 0.0, n = 0.0
                for yy in y0..<min(height, y1) { for xx in x0..<min(width, x1) { sum += l[yy * width + xx]; n += 1 } }
                out[y * tw + x] = n > 0 ? sum / n : 0
            }
        }
        return (out, tw, th)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
    }

    /// The share of pixels with low chroma in the mid lightness.
    static func mudShare(of raster: Raster) -> Double {
        var mud = 0
        let count = raster.width * raster.height
        for i in 0..<count {
            let o = i * 4
            let lch = OKLCH(RGBAColor(red: Double(raster.pixels[o]) / 255, green: Double(raster.pixels[o + 1]) / 255, blue: Double(raster.pixels[o + 2]) / 255))
            if lch.c < 0.045, lch.l > 0.28, lch.l < 0.62 { mud += 1 }
        }
        return count > 0 ? Double(mud) / Double(count) : 0
    }

    /// The share of `patch`-sized patches whose lightness barely varies.
    static func quietShare(_ l: [Double], width: Int, height: Int, patch: Int = 16) -> Double {
        let px = width / patch, py = height / patch
        guard px > 0, py > 0 else { return 0 }
        var quiet = 0
        for y in 0..<py {
            for x in 0..<px {
                var sum = 0.0, squares = 0.0
                for yy in 0..<patch { for xx in 0..<patch { let v = l[(y * patch + yy) * width + x * patch + xx]; sum += v; squares += v * v } }
                let n = Double(patch * patch)
                let mean = sum / n
                if (squares / n - mean * mean).squareRoot() < 0.035 { quiet += 1 }
            }
        }
        return Double(quiet) / Double(px * py)
    }

    /// Mean absolute difference of two rasters of one size, per channel, 0…1.
    static func distance(_ a: Raster, _ b: Raster) -> Double {
        guard a.size == b.size else { return 1 }
        var sum = 0
        for i in 0..<a.pixels.count where i % 4 != 3 { sum += abs(Int(a.pixels[i]) - Int(b.pixels[i])) }
        return Double(sum) / Double(a.width * a.height * 3 * 255)
    }
}

extension Wallpaper {
    /// Whether the menu bar's text reads over this document's top strip on
    /// a side, by the gate's rule (`MenuBarReadability.readsEitherText`),
    /// rendered small.
    public func menuBarReads(side: Side, context: RenderContext, renderer: WallpaperRenderer = WallpaperRenderer()) -> Bool {
        let raster = renderer.render(self, side: side, context: context)
        return MenuBarReadability.assess(raster, stripHeight: context.menuBarStrip, side: side).readsEitherText
    }

    /// The document with the smallest top shade, in tenths from the one it
    /// has, at which the menu bar reads on both sides; a full shade always
    /// reads (the strip becomes one tone), so this ends. A preset applied
    /// in the panel goes through here so no look lands with an unreadable
    /// menu bar; Shuffle has its own single repair inside the gate.
    public func liftingMenuBar(context: RenderContext, renderer: WallpaperRenderer = WallpaperRenderer()) -> Wallpaper {
        var out = self
        var shade = finish.topShade
        while true {
            out.finish.topShade = shade
            if Side.allCases.allSatisfy({ out.menuBarReads(side: $0, context: context, renderer: renderer) }) { return out }
            if shade >= 1 { return out }
            shade = min(1, (shade * 10).rounded(.down) / 10 + 0.1)
        }
    }
}

extension MenuBarReadability {
    /// The text color macOS would draw over the strip: the one with the
    /// better contrast against its mean.
    public var likelyTextIsWhite: Bool { contrastWithWhite >= contrastWithBlack }

    /// The strip reads under the text color macOS would pick, everywhere
    /// along it: every one of the sixteen patches at 3:1 or better against
    /// that text, the strip as a whole at 4.5:1, and not too busy. The
    /// mean alone always finds one color at 4.58:1, so the patches are the
    /// rule; a white patch on a black strip fails it.
    public var readsEitherText: Bool {
        let white = likelyTextIsWhite
        let overall = white ? contrastWithWhite : contrastWithBlack
        let weakest = patchLuminances.map { MenuBarReadability.contrast(luminance: $0, white: white) }.min() ?? overall
        return overall >= 4.5 && weakest >= 3 && luminanceSpread < 0.3
    }
}
