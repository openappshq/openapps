import Foundation

/// A wallpaper is a document, not an image: a generator, its parameters, a
/// seed, the finishes, the pair and the composition. The same document
/// renders the same pixels at the same size on every Mac; a favorite is a
/// document, and renders again for any display.
///
/// JSON, version 3: `{"version":3,"generator":{"type":"field",…},"seed":"…",
/// "grain":0.1,"finish":{…},"pair":{"mode":"still"},"composition":"none",
/// "base":{"layer":"gradient",…},"pinned":["cellSize"]}`. Version-1 and -2
/// documents decode with the defaults (no base, nothing pinned). The seed
/// is a decimal string so it survives JSON parsers that round 64-bit
/// integers.
public struct Wallpaper: Codable, Hashable, Sendable {
    public static let currentVersion = 3

    public var generator: Generator
    public var seed: UInt64
    /// Film grain, 0…1, a seeded monochrome finish on every generator.
    public var grain: Double
    /// Tint, duotone, gradient map, wash, vignette, fringe and the top shade.
    public var finish: Finish
    /// Still, a light/dark pair, or a time-of-day set.
    public var pair: PairMode
    /// The dark side, when the user edited it; nil derives it from the
    /// light side (`Generator.darkened`).
    public var darkGenerator: Generator?
    /// How the render composes around the notch.
    public var composition: Composition
    /// What lies under a texture: a pattern's paper, interference's ground,
    /// what a dither without a photo dithers, the backdrop of a fitted
    /// image. `.none` keeps the generator's own colors.
    public var base: BaseLayer
    /// The parameters Shuffle keeps from this document.
    public var pinned: Set<ParameterKey>

    public init(
        generator: Generator, seed: UInt64, grain: Double = 0, finish: Finish = Finish(), pair: PairMode = .still,
        darkGenerator: Generator? = nil, composition: Composition = .none, base: BaseLayer = .none, pinned: Set<ParameterKey> = []
    ) {
        self.generator = generator
        self.seed = seed
        self.grain = min(max(grain, 0), 1)
        self.finish = finish
        self.pair = pair
        self.darkGenerator = darkGenerator
        self.composition = composition
        self.base = base
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case version, generator, seed, grain, finish, pair, darkGenerator, composition, base, pinned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Wallpaper version \(version) is newer than \(Self.currentVersion)")
        }
        generator = try container.decode(Generator.self, forKey: .generator)
        let seedText = try container.decode(String.self, forKey: .seed)
        guard let seed = UInt64(seedText) else {
            throw DecodingError.dataCorruptedError(forKey: .seed, in: container, debugDescription: "Not a seed: \(seedText)")
        }
        self.seed = seed
        grain = try container.decodeFiniteIfPresent(Double.self, forKey: .grain, in: 0...1, default: 0)
        finish = try container.decodeIfPresent(Finish.self, forKey: .finish) ?? Finish()
        pair = try container.decodeIfPresent(PairMode.self, forKey: .pair) ?? .still
        darkGenerator = try container.decodeIfPresent(Generator.self, forKey: .darkGenerator)
        composition = try container.decodeIfPresent(Composition.self, forKey: .composition) ?? .none
        base = try container.decodeIfPresent(BaseLayer.self, forKey: .base) ?? .none
        // An unknown key (a newer app's parameter) is dropped, not refused.
        let keys = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        guard keys.count <= ParameterKey.allCases.count * 2 else {
            throw DecodingError.dataCorruptedError(forKey: .pinned, in: container, debugDescription: "Too many pins")
        }
        pinned = Set(keys.compactMap(ParameterKey.init(rawValue:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(generator, forKey: .generator)
        try container.encode(String(seed), forKey: .seed)
        try container.encode(grain, forKey: .grain)
        try container.encode(finish, forKey: .finish)
        try container.encode(pair, forKey: .pair)
        try container.encodeIfPresent(darkGenerator, forKey: .darkGenerator)
        try container.encode(composition, forKey: .composition)
        if base != .none { try container.encode(base, forKey: .base) }
        if !pinned.isEmpty { try container.encode(pinned.map(\.rawValue).sorted(), forKey: .pinned) }
    }

    // MARK: - JSON

    /// Stable key order, no whitespace: the same document always gives the
    /// same bytes, so a favorite compares by content.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> Wallpaper {
        try JSONDecoder().decode(Wallpaper.self, from: data)
    }

    /// The seed in the form the panel shows and the user can type back.
    public var seedText: String { String(seed) }

    /// The same document with another seed.
    public func reseeded(_ seed: UInt64 = .randomSeed()) -> Wallpaper {
        var copy = self
        copy.seed = seed
        return copy
    }

    // MARK: - Sides

    /// The generator of a side: the light one, or the dark one (edited, or
    /// derived from the light one).
    public func generator(for side: Side) -> Generator {
        switch side {
        case .light: generator
        case .dark: darkGenerator ?? generator.darkened()
        }
    }

    /// The base of a side: the light one, or its colors folded down the way
    /// the dark generator is derived (a base is never edited per side).
    public func base(for side: Side) -> BaseLayer {
        switch side {
        case .light: base
        case .dark: base.recolored(Generator.darkenColor)
        }
    }

    /// The finish of a side: the wash's colors fold down on the dark side;
    /// tint, duotone and the gradient map are the user's own on both.
    public func finish(for side: Side) -> Finish {
        guard side == .dark, let wash = finish.wash else { return finish }
        var copy = finish
        copy.wash = Wash(from: Generator.darkenColor(wash.from), to: Generator.darkenColor(wash.to), angle: wash.angle, amount: wash.amount)
        return copy
    }

    /// Whether the dark side was edited by hand (nil derives it).
    public var hasCustomDark: Bool { darkGenerator != nil }

    /// The document with one side's generator replaced (the dark side
    /// materialised as its own).
    public func withSideGenerator(_ side: Side, _ generator: Generator) -> Wallpaper {
        var copy = self
        switch side {
        case .light: copy.generator = generator
        case .dark: copy.darkGenerator = generator
        }
        return copy
    }

    /// Every finish off, grain off: the render is the generator's own pixels.
    public var isPlain: Bool { grain == 0 && finish.isEmpty }

    /// `#000000` with nothing on top — no finish, no grain, no composition,
    /// no base, a still — so every pixel of every side is exact zeros.
    public var isTrueBlack: Bool {
        if case .solid(let p) = generator, p.color == .black { return isPlain && composition == .none && pair == .still && base == .none && (darkGenerator == nil || darkGenerator == generator) }
        return false
    }

    /// The colors the document is made of: the generator's and the base's,
    /// for naming its palette and for the quality gate.
    public var colors: [RGBAColor] {
        generator.colors + base.colors
    }

    /// The document a fresh install starts with: the first recipe of the
    /// taste set (a mint moiré), never applied on its own.
    public static let starter = TasteSet.recipes[0].wallpaper

    /// True black: `#000000`, nothing else. Not in the picker any more; a
    /// document keeps decoding, and it is the ground of choice under a
    /// texture (`BaseLayer.trueBlack`).
    public static let trueBlack = Wallpaper(generator: .solid(SolidParameters(color: .black)), seed: 0)

    /// A random document: never uniform noise over the parameter space,
    /// always a curated recipe family drawn with a preset palette and
    /// passed through the quality gate (Curation.swift). With nothing
    /// pinned the gate is always satisfied within the attempts in
    /// practice; should it not be, a taste-set recipe stands in — a
    /// document that passed the gate by test, never a refused candidate.
    public static func random(using generator: inout SeededGenerator) -> Wallpaper {
        if let document = Shuffle.next(from: nil, using: &generator).document { return document }
        return TasteSet.recipes[Int(generator.next() % UInt64(TasteSet.recipes.count))].wallpaper
    }
}

/// What lies under a texture. JSON carries a `layer` discriminator beside
/// the layer's own parameters: `{"layer":"solid","color":"#000000"}`,
/// `{"layer":"gradient","kind":"radial",…}`, `{"layer":"mesh",…}`; an
/// absent base is `.none`.
public enum BaseLayer: Hashable, Sendable {
    case none
    case solid(RGBAColor)
    case gradient(GradientParameters)
    case mesh(MeshParameters)

    public static let trueBlack = BaseLayer.solid(.black)

    public var title: String {
        switch self {
        case .none: "None"
        case .solid: "Flat"
        case .gradient: "Gradient"
        case .mesh: "Mesh"
        }
    }

    /// The base's own colors, in order.
    public var colors: [RGBAColor] {
        switch self {
        case .none: []
        case .solid(let color): [color]
        case .gradient(let p): p.stops.map(\.color)
        case .mesh(let p): p.colors
        }
    }

    /// The same base with every color passed through `transform`.
    public func recolored(_ transform: (RGBAColor) -> RGBAColor) -> BaseLayer {
        switch self {
        case .none: return .none
        case .solid(let color): return .solid(transform(color))
        case .gradient(var p):
            p.stops = p.stops.map { ColorStop(position: $0.position, color: transform($0.color)) }
            return .gradient(p)
        case .mesh(var p):
            p.colors = p.colors.map(transform)
            return .mesh(p)
        }
    }

    /// A base of a kind from a palette: a flat ground, a two-stop gradient
    /// from the ground toward the next tone (smooth), or a mesh of the
    /// palette's darker half.
    public static func `default`(_ kind: BaseKind, colors: [RGBAColor]) -> BaseLayer {
        let palette = colors.isEmpty ? Palettes.all[0] : colors
        let ground = palette[0]
        switch kind {
        case .none: return .none
        case .solid: return .solid(ground)
        case .gradient:
            let second = (palette.count > 1 ? OKLCH.mix(ground, palette[1], amount: 0.45) : OKLCH.mix(ground, .white, amount: 0.2)).snapped
            return .gradient(GradientParameters(kind: .linear, angle: 115, stops: [ColorStop(position: 0, color: ground), ColorStop(position: 1, color: second)], interpolation: .oklch))
        case .mesh:
            let second = (palette.count > 1 ? OKLCH.mix(ground, palette[1], amount: 0.5) : OKLCH.mix(ground, .white, amount: 0.25)).snapped
            let third = (palette.count > 2 ? OKLCH.mix(ground, palette[2], amount: 0.35) : OKLCH.mix(ground, .black, amount: 0.3)).snapped
            return .mesh(MeshParameters(columns: 3, rows: 2, colors: [ground, second, third], jitter: 0.5, softness: 0.7))
        }
    }

    public var kind: BaseKind {
        switch self {
        case .none: .none
        case .solid: .solid
        case .gradient: .gradient
        case .mesh: .mesh
        }
    }
}

/// The base row's choices.
public enum BaseKind: String, Codable, CaseIterable, Hashable, Sendable {
    case none, solid, gradient, mesh

    public var title: String {
        switch self {
        case .none: "None"
        case .solid: "Flat"
        case .gradient: "Gradient"
        case .mesh: "Mesh"
        }
    }
}

extension BaseLayer: Codable {
    private enum CodingKeys: String, CodingKey { case layer, color }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(BaseKind.self, forKey: .layer) {
        case .none: self = .none
        case .solid: self = .solid(try container.decode(RGBAColor.self, forKey: .color))
        case .gradient: self = .gradient(try GradientParameters(from: decoder))
        case .mesh: self = .mesh(try MeshParameters(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .layer)
        switch self {
        case .none: break
        case .solid(let color): try container.encode(color, forKey: .color)
        case .gradient(let p): try p.encode(to: encoder)
        case .mesh(let p): try p.encode(to: encoder)
        }
    }
}

/// A parameter Shuffle can be told to keep, and the key of a pixel-field
/// knob. Keys name the knobs the panel shows; a key that does not apply
/// to a document's generator is carried but ignored.
public enum ParameterKey: String, Codable, CaseIterable, Hashable, Sendable {
    // The document.
    case generator, palette, seed, base, composition, pair
    // Every pixel field.
    case family, cellSize, toneSteps, dither, oklab, depth, anchorX, anchorY, reach, angle, offset, reflect
    // Interference.
    case mode, twist, repeatX, repeatY
    // Contour relief, islands.
    case scale, warp, rim, relief, seaLevel, roughness, shore, focal
    // Resonance plate.
    case modeM, modeN, balance, nodalWidth, density
    // Woven circuit.
    case ribbon, bias, biasScale, loops, gap, accent
    // Memory sky.
    case horizon, sunX, sunRadius, haze, ridge, clouds, diffusion
    // Mesh and pattern, pixelize and dither.
    case columns, rows, jitter, softness, patternKind, blockSize, ditherMode, cell, paletteSize, framing
    // Gradient.
    case gradientKind, center, interpolation
    // Finishes.
    case grain, topShade, tint, duotone, gradientMap, wash, vignette, fringe

    public var title: String {
        switch self {
        case .generator: "Generator"
        case .palette: "Palette"
        case .seed: "Seed"
        case .base: "Base"
        case .composition: "Notch"
        case .pair: "Pair"
        case .family: "Family"
        case .cellSize: "Cell size"
        case .toneSteps: "Tone steps"
        case .dither: "Dither"
        case .oklab: "OKLab"
        case .depth: "Depth"
        case .anchorX: "Anchor X"
        case .anchorY: "Anchor Y"
        case .reach: "Reach"
        case .angle: "Angle"
        case .offset: "Offset"
        case .reflect: "Reflect"
        case .mode: "Field"
        case .twist: "Twist"
        case .repeatX: "Repeat X"
        case .repeatY: "Repeat Y"
        case .scale: "Scale"
        case .warp: "Warp"
        case .rim: "Rim"
        case .relief: "Relief"
        case .seaLevel: "Sea level"
        case .roughness: "Roughness"
        case .shore: "Shore"
        case .focal: "Focus"
        case .modeM: "Mode M"
        case .modeN: "Mode N"
        case .balance: "Balance"
        case .nodalWidth: "Nodal width"
        case .density: "Density"
        case .ribbon: "Ribbon"
        case .bias: "Bias"
        case .biasScale: "Bias scale"
        case .loops: "Loops"
        case .gap: "Gap"
        case .accent: "Accent"
        case .horizon: "Horizon"
        case .sunX: "Sun X"
        case .sunRadius: "Sun"
        case .haze: "Haze"
        case .ridge: "Ridges"
        case .clouds: "Clouds"
        case .diffusion: "Diffusion"
        case .columns: "Columns"
        case .rows: "Rows"
        case .jitter: "Jitter"
        case .softness: "Softness"
        case .patternKind: "Pattern"
        case .blockSize: "Block"
        case .ditherMode: "Mode"
        case .cell: "Cell"
        case .paletteSize: "Colors"
        case .framing: "Framing"
        case .gradientKind: "Shape"
        case .center: "Center"
        case .interpolation: "Blend"
        case .grain: "Grain"
        case .topShade: "Top shade"
        case .tint: "Tint"
        case .duotone: "Duotone"
        case .gradientMap: "Gradient map"
        case .wash: "Wash"
        case .vignette: "Vignette"
        case .fringe: "Fringe"
        }
    }
}

/// The light or the dark side of a document.
public enum Side: String, Codable, CaseIterable, Hashable, Sendable {
    case light, dark

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Still, a light/dark pair, or a time-of-day set of frames. JSON:
/// `{"mode":"still"}`, `{"mode":"lightDark"}`, `{"mode":"timeOfDay","frames":8}`.
public enum PairMode: Hashable, Sendable {
    case still
    case lightDark
    case timeOfDay(frames: Int)

    public static let frameCounts = [4, 8, 16]

    public var title: String {
        switch self {
        case .still: "Still"
        case .lightDark: "Light / Dark"
        case .timeOfDay(let frames): "Time of day · \(frames)"
        }
    }

    public var isStill: Bool { self == .still }
}

extension PairMode: Codable {
    private enum CodingKeys: String, CodingKey { case mode, frames }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .mode) {
        case "still": self = .still
        case "lightDark": self = .lightDark
        case "timeOfDay":
            let frames = try container.decodeIfPresent(Int.self, forKey: .frames) ?? 8
            self = .timeOfDay(frames: Self.frameCounts.contains(frames) ? frames : 8)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Not a pair mode: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .still: try container.encode("still", forKey: .mode)
        case .lightDark: try container.encode("lightDark", forKey: .mode)
        case .timeOfDay(let frames):
            try container.encode("timeOfDay", forKey: .mode)
            try container.encode(frames, forKey: .frames)
        }
    }
}

/// How a render composes around the notch of the display it is made for.
public enum Composition: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    /// The mesh's brightest point sits at the cutout's bottom center and the
    /// field grows out of it; a radial or conic gradient centers there.
    case emerge
    /// Contour lines part around the notch pill.
    case contours
    /// A black pill of the notch's proportion painted at the top center of a
    /// display without one.
    case pill

    public var title: String {
        switch self {
        case .none: "None"
        case .emerge: "Emerge"
        case .contours: "Contours"
        case .pill: "Painted pill"
        }
    }
}

// MARK: - Finishes

/// One color mixed over the whole render.
public struct Tint: Codable, Hashable, Sendable {
    public var color: RGBAColor
    /// 0…1.
    public var amount: Double

    public init(color: RGBAColor, amount: Double) {
        self.color = color
        self.amount = min(max(amount, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case color, amount }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try container.decode(RGBAColor.self, forKey: .color), amount: try container.decodeFinite(Double.self, forKey: .amount, in: 0...1))
    }
}

/// Luminance mapped between two colors.
public struct Duotone: Codable, Hashable, Sendable {
    public var shadow: RGBAColor
    public var highlight: RGBAColor

    public init(shadow: RGBAColor, highlight: RGBAColor) {
        self.shadow = shadow
        self.highlight = highlight
    }
}

/// A gradient of two colors laid over the render at an amount: the soft
/// color drift that keeps a flat texture from looking flat.
public struct Wash: Codable, Hashable, Sendable {
    public var from: RGBAColor
    public var to: RGBAColor
    /// Degrees, as a linear gradient's.
    public var angle: Double
    /// 0…1.
    public var amount: Double

    public init(from: RGBAColor, to: RGBAColor, angle: Double = 135, amount: Double = 0.25) {
        self.from = from
        self.to = to
        self.angle = angle
        self.amount = min(max(amount, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case from, to, angle, amount }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            from: try container.decode(RGBAColor.self, forKey: .from), to: try container.decode(RGBAColor.self, forKey: .to),
            angle: try container.decodeFiniteIfPresent(Double.self, forKey: .angle, in: GradientParameters.angleRange, default: 135),
            amount: try container.decodeFinite(Double.self, forKey: .amount, in: 0...1)
        )
    }
}

/// The finishes after the generator, in the order they apply: tint,
/// duotone, gradient map, wash, vignette, fringe, (grain, on the
/// document), top shade.
public struct Finish: Codable, Hashable, Sendable {
    public var tint: Tint?
    public var duotone: Duotone?
    /// 2–6 stops over luminance, 0 = darkest.
    public var gradientMap: [ColorStop]?
    /// A color gradient mixed over the whole render.
    public var wash: Wash?
    /// A darkening toward the corners, 0…1.
    public var vignette: Double
    /// A chromatic fringe: the red and blue channels pulled apart at every
    /// edge, 0…1 (a pixel at 0.2, six at 1).
    public var fringe: Double
    /// A darkening of the menu-bar strip, 0…1, so its text reads.
    public var topShade: Double

    public init(tint: Tint? = nil, duotone: Duotone? = nil, gradientMap: [ColorStop]? = nil, wash: Wash? = nil, vignette: Double = 0, fringe: Double = 0, topShade: Double = 0) {
        self.tint = tint
        self.duotone = duotone
        self.gradientMap = gradientMap
        self.wash = wash
        self.vignette = min(max(vignette, 0), 1)
        self.fringe = min(max(fringe, 0), 1)
        self.topShade = min(max(topShade, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case tint, duotone, gradientMap, wash, vignette, fringe, topShade }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tint = try container.decodeIfPresent(Tint.self, forKey: .tint)
        duotone = try container.decodeIfPresent(Duotone.self, forKey: .duotone)
        gradientMap = try container.decodeIfPresent([ColorStop].self, forKey: .gradientMap)
        if let map = gradientMap, !GradientParameters.stopRange.contains(map.count) {
            throw DecodingError.dataCorruptedError(forKey: .gradientMap, in: container, debugDescription: "A gradient map has \(GradientParameters.stopRange) stops, not \(map.count)")
        }
        wash = try container.decodeIfPresent(Wash.self, forKey: .wash)
        vignette = try container.decodeFiniteIfPresent(Double.self, forKey: .vignette, in: 0...1, default: 0)
        fringe = try container.decodeFiniteIfPresent(Double.self, forKey: .fringe, in: 0...1, default: 0)
        topShade = try container.decodeFiniteIfPresent(Double.self, forKey: .topShade, in: 0...1, default: 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tint, forKey: .tint)
        try container.encodeIfPresent(duotone, forKey: .duotone)
        try container.encodeIfPresent(gradientMap, forKey: .gradientMap)
        try container.encodeIfPresent(wash, forKey: .wash)
        if vignette > 0 { try container.encode(vignette, forKey: .vignette) }
        if fringe > 0 { try container.encode(fringe, forKey: .fringe) }
        try container.encode(topShade, forKey: .topShade)
    }

    public var isEmpty: Bool { tint == nil && duotone == nil && gradientMap == nil && wash == nil && vignette == 0 && fringe == 0 && topShade == 0 }

    /// The same finish with every color passed through `transform`.
    public func recolored(_ transform: (RGBAColor) -> RGBAColor) -> Finish {
        var copy = self
        if let tint { copy.tint = Tint(color: transform(tint.color), amount: tint.amount) }
        if let duotone { copy.duotone = Duotone(shadow: transform(duotone.shadow), highlight: transform(duotone.highlight)) }
        if let gradientMap { copy.gradientMap = gradientMap.map { ColorStop(position: $0.position, color: transform($0.color)) } }
        if let wash { copy.wash = Wash(from: transform(wash.from), to: transform(wash.to), angle: wash.angle, amount: wash.amount) }
        return copy
    }
}

// MARK: - Generators

/// Which generator a document uses; the panel's picker.
public enum GeneratorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case gradient, mesh, pattern, solid, pixelize, dither, field

    public var title: String {
        switch self {
        case .gradient: "Gradient"
        case .mesh: "Mesh"
        case .pattern: "Pattern"
        case .solid: "Solid"
        case .pixelize: "Pixelize"
        case .dither: "Dither"
        case .field: "Pixel field"
        }
    }

    /// The picker's order: the textures first, gradient last as the
    /// advanced pick. Solid is not offered (a flat color is a base under a
    /// texture); a solid document still decodes and renders.
    public static let pickable: [GeneratorKind] = [.field, .dither, .pattern, .mesh, .pixelize, .gradient]

    /// The generators Shuffle can make from nothing: the curated families'
    /// kinds (Curation.swift). Never a bare gradient, never a solid.
    public static let shuffleable: [GeneratorKind] = [.field, .dither, .pattern, .mesh]

    /// The generators the panel's Generators section lists, in its order
    /// (the pixel-field families expand first, see `GeneratorChoice`); a
    /// flat color and a gradient are the base layer, chosen under Effects.
    public static let panelOrder: [GeneratorKind] = [.field, .dither, .mesh, .pixelize, .pattern]

    /// The kinds that only ever serve as a base under a texture.
    public static let baseLayers: [GeneratorKind] = [.solid, .gradient]

    public var isBaseLayer: Bool { Self.baseLayers.contains(self) }

    /// One line under the generator's name in the panel.
    public var summary: String {
        switch self {
        case .gradient: "A gradient on its own: linear, radial or conic."
        case .mesh: "Control points blended into one soft field."
        case .pattern: "Dots, lines, checks or noise in two colors."
        case .solid: "One flat color."
        case .pixelize: "Your photo in blocks, optionally a small palette."
        case .dither: "Your photo — or the base — through Bayer, blue noise, halftone or ASCII."
        case .field: "Six authored looks on a pixel grid: moiré, relief, islands, plate, circuit, sky."
        }
    }

    /// The SF Symbol the panel's lists use.
    public var symbolName: String {
        switch self {
        case .gradient: "square.lefthalf.filled"
        case .mesh: "circle.hexagongrid"
        case .pattern: "circle.grid.3x3"
        case .solid: "square.fill"
        case .pixelize: "squareshape.split.3x3"
        case .dither: "checkerboard.rectangle"
        case .field: "waveform.path"
        }
    }

    /// The generators that work on an imported image.
    public var needsSource: Bool { self == .pixelize || self == .dither }

    /// The generators whose ground is the base layer when one is set.
    public var takesBase: Bool { self == .pattern || self == .field || self == .dither || self == .pixelize }
}

/// One entry of the panel's Generators list: a pixel-field family or a
/// generator kind, in the order the panel shows them — the six families
/// first, then dither, mesh, pixelize and pattern. Gradient and solid are
/// base layers, not entries.
public enum GeneratorChoice: Hashable, Sendable, Identifiable {
    case family(FieldFamily)
    case kind(GeneratorKind)

    public static let panelOrder: [GeneratorChoice] = FieldFamily.allCases.map { .family($0) } + GeneratorKind.panelOrder.filter { $0 != .field }.map { .kind($0) }

    public var id: String {
        switch self {
        case .family(let family): "family.\(family.rawValue)"
        case .kind(let kind): "kind.\(kind.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case .family(let family): family.title
        case .kind(let kind): kind.title
        }
    }

    public var summary: String {
        switch self {
        case .family(let family): family.summary
        case .kind(let kind): kind.summary
        }
    }

    public var symbolName: String {
        switch self {
        case .family(let family): family.symbolName
        case .kind(let kind): kind.symbolName
        }
    }

    public var kind: GeneratorKind {
        switch self {
        case .family: .field
        case .kind(let kind): kind
        }
    }

    /// The choice a document is: its family for a field, its kind otherwise.
    public init(_ generator: Generator) {
        if case .field(let p) = generator { self = .family(p.family) } else { self = .kind(generator.kind) }
    }
}

extension Generator {
    /// The pixel-field family, nil for the other kinds.
    public var fieldFamily: FieldFamily? {
        if case .field(let p) = self { p.family } else { nil }
    }
}

/// The generator and its parameters. JSON carries a `type` discriminator
/// beside the parameters: `{"type":"gradient","kind":"linear",…}`.
public enum Generator: Hashable, Sendable {
    case gradient(GradientParameters)
    case mesh(MeshParameters)
    case pattern(PatternParameters)
    case solid(SolidParameters)
    case pixelize(PixelizeParameters)
    case dither(DitherParameters)
    case field(FieldParameters)

    public var kind: GeneratorKind {
        switch self {
        case .gradient: .gradient
        case .mesh: .mesh
        case .pattern: .pattern
        case .solid: .solid
        case .pixelize: .pixelize
        case .dither: .dither
        case .field: .field
        }
    }

    /// The default parameters when the user switches to a generator,
    /// carrying the colors of the current one where that makes sense, and
    /// the source image between pixelize and dither.
    public static func `default`(_ kind: GeneratorKind, colors: [RGBAColor], source: ImageReference? = nil) -> Generator {
        let palette = colors.isEmpty ? Palettes.all[0] : colors
        switch kind {
        case .gradient:
            let count = min(max(palette.count, 2), 6)
            let stops = (0..<count).map { i in ColorStop(position: Double(i) / Double(count - 1), color: palette[i % palette.count]) }
            return .gradient(GradientParameters(kind: .linear, angle: 135, stops: stops, interpolation: .oklch))
        case .mesh:
            return .mesh(MeshParameters(columns: 3, rows: 3, colors: Array(palette.prefix(6)), jitter: 0.5, softness: 0.5))
        case .pattern:
            return .pattern(PatternParameters(kind: .dots, foreground: palette.count > 1 ? palette[1] : .white, background: palette[0], scale: 48, angle: 0))
        case .solid:
            return .solid(SolidParameters(color: palette[0]))
        case .pixelize:
            return .pixelize(PixelizeParameters(source: source, blockSize: 16, paletteSize: nil, fit: .fill, background: palette[0]))
        case .dither:
            return .dither(DitherParameters(source: source, mode: .floydSteinberg, cell: 2, ink: palette.count > 1 ? palette[1] : .white, paper: palette[0]))
        case .field:
            return .field(FieldParameters(family: .interference, tones: palette.map(\.snapped)))
        }
    }

    /// The colors the generator uses, in order, for carrying over on a switch.
    public var colors: [RGBAColor] {
        switch self {
        case .gradient(let p): p.stops.map(\.color)
        case .mesh(let p): p.colors
        case .pattern(let p): [p.background, p.foreground]
        case .solid(let p): [p.color]
        case .pixelize(let p): [p.background]
        case .dither(let p): [p.paper, p.ink]
        case .field(let p): p.tones
        }
    }

    /// The imported image, for the generators that take one.
    public var source: ImageReference? {
        switch self {
        case .pixelize(let p): p.source
        case .dither(let p): p.source
        default: nil
        }
    }

    /// The same generator in another palette, as many of its colors as it
    /// takes: a gradient's stops are respaced over them, a mesh takes up to
    /// six, the two-color generators take the first as the ground and the
    /// last as the ink, a field takes up to six tones. An empty palette
    /// changes nothing; one color becomes a ramp of itself
    /// (`Palettes.usable`), so no generator ever holds a single tone.
    public func withPalette(_ colors: [RGBAColor]) -> Generator {
        guard !colors.isEmpty else { return self }
        let colors = Palettes.usable(colors)
        switch self {
        case .gradient(var p):
            let count = min(max(colors.count, GradientParameters.stopRange.lowerBound), GradientParameters.stopRange.upperBound)
            p.stops = (0..<count).map { i in ColorStop(position: Double(i) / Double(count - 1), color: colors[i % colors.count]) }
            return .gradient(p)
        case .mesh(var p):
            p.colors = Array(colors.prefix(MeshParameters.colorRange.upperBound))
            return .mesh(p)
        case .pattern(var p):
            p.background = colors[0]
            p.foreground = colors.count > 1 ? colors[colors.count - 1] : p.foreground
            return .pattern(p)
        case .solid(var p):
            p.color = colors[0]
            return .solid(p)
        case .pixelize(var p):
            p.background = colors[0]
            return .pixelize(p)
        case .dither(var p):
            p.paper = colors[0]
            p.ink = colors.count > 1 ? colors[colors.count - 1] : p.ink
            return .dither(p)
        case .field(var p):
            p.tones = colors
            return .field(p)
        }
    }

    /// The same generator with every color passed through `transform`:
    /// the dark side, the day curve, a palette swap.
    public func recolored(_ transform: (RGBAColor) -> RGBAColor) -> Generator {
        switch self {
        case .gradient(var p):
            p.stops = p.stops.map { ColorStop(position: $0.position, color: transform($0.color)) }
            return .gradient(p)
        case .mesh(var p):
            p.colors = p.colors.map(transform)
            return .mesh(p)
        case .pattern(var p):
            p.foreground = transform(p.foreground)
            p.background = transform(p.background)
            return .pattern(p)
        case .solid(var p):
            p.color = transform(p.color)
            return .solid(p)
        case .pixelize(var p):
            p.background = transform(p.background)
            return .pixelize(p)
        case .dither(var p):
            p.ink = transform(p.ink)
            p.paper = transform(p.paper)
            p.background = transform(p.background)
            return .dither(p)
        case .field(var p):
            p.tones = p.tones.map(transform)
            return .field(p)
        }
    }

    /// The dark side derived from the light one: every color's OKLCH
    /// lightness folded down (0 → 0.12, 1 → 0.47), hue and chroma kept
    /// (chroma capped so a bright color does not glow in the dark). Pure
    /// black stays pure black, so true black is exact zeros on both sides.
    public func darkened() -> Generator {
        recolored(Self.darkenColor)
    }

    /// The fold of one color; the base and the wash use the same. Byte
    /// exact, so a materialised dark side round-trips.
    public static func darkenColor(_ color: RGBAColor) -> RGBAColor {
        if color.red == 0, color.green == 0, color.blue == 0 { return color }
        var lch = OKLCH(color)
        lch.l = 0.12 + 0.35 * lch.l
        lch.c = min(lch.c, 0.12)
        return lch.color.snapped
    }

    /// The colors at a moment of the day, 0 = midnight, 0.5 = noon: lightness
    /// and chroma down toward the night, a touch of warmth at dawn and dusk.
    public func atTimeOfDay(_ t: Double) -> Generator {
        let daylight = (1 - cos(2 * .pi * t)) / 2   // 0 at midnight, 1 at noon
        let twilight = 1 - abs(2 * daylight - 1)     // 1 at dawn and dusk, 0 at noon and midnight
        return recolored { color in
            var lch = OKLCH(color)
            lch.l *= 0.35 + 0.65 * daylight
            lch.c *= 0.6 + 0.4 * daylight
            // Toward the warm side (hue ~ 60°) by up to 12° at dawn and dusk.
            if lch.c > 0.01 { lch.h += OKLCH.hueDelta(from: lch.h, to: 60) >= 0 ? 12 * twilight : -12 * twilight }
            return lch.color
        }
    }
}

extension Generator: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(GeneratorKind.self, forKey: .type)
        switch kind {
        case .gradient: self = .gradient(try GradientParameters(from: decoder))
        case .mesh: self = .mesh(try MeshParameters(from: decoder))
        case .pattern: self = .pattern(try PatternParameters(from: decoder))
        case .solid: self = .solid(try SolidParameters(from: decoder))
        case .pixelize: self = .pixelize(try PixelizeParameters(from: decoder))
        case .dither: self = .dither(try DitherParameters(from: decoder))
        case .field: self = .field(try FieldParameters(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .gradient(let p): try p.encode(to: encoder)
        case .mesh(let p): try p.encode(to: encoder)
        case .pattern(let p): try p.encode(to: encoder)
        case .solid(let p): try p.encode(to: encoder)
        case .pixelize(let p): try p.encode(to: encoder)
        case .dither(let p): try p.encode(to: encoder)
        case .field(let p): try p.encode(to: encoder)
        }
    }
}

/// A point in unit coordinates: (0, 0) top-left, (1, 1) bottom-right.
public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = Point(x: 0.5, y: 0.5)

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeFinite(Double.self, forKey: .x, in: 0...1)
        y = try container.decodeFinite(Double.self, forKey: .y, in: 0...1)
    }
}

public enum GradientKind: String, Codable, CaseIterable, Hashable, Sendable {
    case linear, radial, conic

    public var title: String {
        switch self {
        case .linear: "Linear"
        case .radial: "Radial"
        case .conic: "Conic"
        }
    }
}

/// How colors between stops are mixed: in sRGB (the version-1 default) or
/// in OKLCH ("smooth": hue turns the short way, no grey dip between
/// saturated colors).
public enum ColorInterpolation: String, Codable, CaseIterable, Hashable, Sendable {
    case srgb, oklch

    public var title: String {
        switch self {
        case .srgb: "sRGB"
        case .oklch: "Smooth"
        }
    }
}

public struct GradientParameters: Codable, Hashable, Sendable {
    public static let stopRange = 2...6

    public var kind: GradientKind
    /// Degrees. Linear: 0 runs left to right, 90 top to bottom. Conic: where
    /// the first stop starts, clockwise from the right.
    public var angle: Double
    /// Radial and conic center.
    public var center: Point
    public var stops: [ColorStop]
    public var interpolation: ColorInterpolation

    public init(kind: GradientKind, angle: Double = 135, center: Point = .center, stops: [ColorStop], interpolation: ColorInterpolation = .srgb) {
        self.kind = kind
        self.angle = angle
        self.center = center
        self.stops = stops
        self.interpolation = interpolation
    }

    private enum CodingKeys: String, CodingKey { case kind, angle, center, stops, interpolation }

    public static let angleRange: ClosedRange<Double> = -720...720

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(GradientKind.self, forKey: .kind)
        angle = try container.decodeFiniteIfPresent(Double.self, forKey: .angle, in: Self.angleRange, default: 135)
        center = try container.decodeIfPresent(Point.self, forKey: .center) ?? .center
        stops = try container.decode([ColorStop].self, forKey: .stops)
        guard Self.stopRange.contains(stops.count) else {
            throw DecodingError.dataCorruptedError(forKey: .stops, in: container, debugDescription: "A gradient has \(Self.stopRange) stops, not \(stops.count)")
        }
        interpolation = try container.decodeIfPresent(ColorInterpolation.self, forKey: .interpolation) ?? .srgb
    }

    /// The stops sorted by position, at least two, positions clamped.
    public var normalizedStops: [ColorStop] {
        var sorted = stops.map { ColorStop(position: min(max($0.position, 0), 1), color: $0.color) }.sorted { $0.position < $1.position }
        if sorted.isEmpty { sorted = [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)] }
        if sorted.count == 1 { sorted.append(ColorStop(position: 1, color: sorted[0].color)) }
        return sorted
    }
}

public struct MeshParameters: Codable, Hashable, Sendable {
    public static let gridRange = 2...5
    public static let colorRange = 2...6

    public var columns: Int
    public var rows: Int
    /// The palette the seed assigns to the control points.
    public var colors: [RGBAColor]
    /// How far a control point may leave its grid cell, 0…1.
    public var jitter: Double
    /// How far each point's color reaches, 0…1.
    public var softness: Double

    public init(columns: Int, rows: Int, colors: [RGBAColor], jitter: Double = 0.5, softness: Double = 0.5) {
        self.columns = min(max(columns, Self.gridRange.lowerBound), Self.gridRange.upperBound)
        self.rows = min(max(rows, Self.gridRange.lowerBound), Self.gridRange.upperBound)
        self.colors = colors.isEmpty ? [.black, .white] : Array(colors.prefix(Self.colorRange.upperBound))
        self.jitter = min(max(jitter, 0), 1)
        self.softness = min(max(softness, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case columns, rows, colors, jitter, softness }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let colors = try container.decode([RGBAColor].self, forKey: .colors)
        guard Self.colorRange.contains(colors.count) else {
            throw DecodingError.dataCorruptedError(forKey: .colors, in: container, debugDescription: "A mesh has \(Self.colorRange) colors, not \(colors.count)")
        }
        self.init(
            columns: try container.decodeBounded(Int.self, forKey: .columns, in: Self.gridRange),
            rows: try container.decodeBounded(Int.self, forKey: .rows, in: Self.gridRange),
            colors: colors,
            jitter: try container.decodeFiniteIfPresent(Double.self, forKey: .jitter, in: 0...1, default: 0.5),
            softness: try container.decodeFiniteIfPresent(Double.self, forKey: .softness, in: 0...1, default: 0.5)
        )
    }
}

public enum PatternKind: String, Codable, CaseIterable, Hashable, Sendable {
    case dots, lines, checks, noise

    public var title: String {
        switch self {
        case .dots: "Dots"
        case .lines: "Lines"
        case .checks: "Checks"
        case .noise: "Noise"
        }
    }
}

public struct PatternParameters: Codable, Hashable, Sendable {
    public static let scaleRange: ClosedRange<Double> = 8...256

    public var kind: PatternKind
    public var foreground: RGBAColor
    public var background: RGBAColor
    /// The repeat, in pixels at the display's scale.
    public var scale: Double
    /// Degrees; lines and checks rotate, dots and noise ignore it.
    public var angle: Double

    public init(kind: PatternKind, foreground: RGBAColor, background: RGBAColor, scale: Double = 48, angle: Double = 0) {
        self.kind = kind
        self.foreground = foreground
        self.background = background
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        self.angle = angle
    }

    private enum CodingKeys: String, CodingKey { case kind, foreground, background, scale, angle }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(PatternKind.self, forKey: .kind),
            foreground: try container.decode(RGBAColor.self, forKey: .foreground),
            background: try container.decode(RGBAColor.self, forKey: .background),
            scale: try container.decodeFiniteIfPresent(Double.self, forKey: .scale, in: Self.scaleRange, default: 48),
            angle: try container.decodeFiniteIfPresent(Double.self, forKey: .angle, in: GradientParameters.angleRange, default: 0)
        )
    }
}

public struct SolidParameters: Codable, Hashable, Sendable {
    public var color: RGBAColor

    public init(color: RGBAColor) {
        self.color = color
    }
}

/// How an imported image is placed on a display of another aspect.
public enum ImageFit: String, Codable, CaseIterable, Hashable, Sendable {
    /// Scaled to cover the display, cropped around the focal point.
    case fill
    /// Scaled to fit inside, the rest in the background color.
    case fit
    /// Scaled to the display's width and height independently.
    case stretch

    public var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        }
    }
}

/// A document's reference to an imported image: the file name under the
/// app's `imports/` folder, plus the content hash it was stored under, so
/// a favorite made on one Mac says what it needs on another. A name is one
/// path component of the generated shape (`<hex>.<ext>`); a document that
/// carries anything else does not decode.
public struct ImageReference: Codable, Hashable, Sendable {
    public var fileName: String
    public var contentHash: String

    public init(fileName: String, contentHash: String) {
        self.fileName = fileName
        self.contentHash = contentHash
    }

    private enum CodingKeys: String, CodingKey { case fileName, contentHash }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .fileName)
        let hash = try container.decode(String.self, forKey: .contentHash)
        guard Self.isValidFileName(name) else {
            throw DecodingError.dataCorruptedError(forKey: .fileName, in: container, debugDescription: "Not an import name: \(name)")
        }
        guard Self.isValidHash(hash) else {
            throw DecodingError.dataCorruptedError(forKey: .contentHash, in: container, debugDescription: "Not a content hash")
        }
        fileName = name
        contentHash = hash
    }

    /// `<up to 64 hex>.<letters>`: no separators, no dot components, nothing hidden.
    public static func isValidFileName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, (8...64).contains(parts[0].count), (1...5).contains(parts[1].count) else { return false }
        return parts[0].allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) } && parts[1].allSatisfy { $0.isLetter && $0.isLowercase }
    }

    /// SHA-256 as 64 lowercase hex characters.
    public static func isValidHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

public struct PixelizeParameters: Codable, Hashable, Sendable {
    public static let blockRange = 4...64
    public static let paletteRange = 2...32

    /// Nil until an image is imported; the panel says so and renders the
    /// background color.
    public var source: ImageReference?
    /// Block edge, in pixels at the display's scale.
    public var blockSize: Int
    /// Nil keeps every block's own average; a count quantises to that many colors.
    public var paletteSize: Int?
    public var fit: ImageFit
    /// Where the crop centers when filling, in unit coordinates of the source.
    public var focus: Point
    /// Behind a fitted image, and the whole render without a source.
    public var background: RGBAColor

    public init(source: ImageReference?, blockSize: Int = 16, paletteSize: Int? = nil, fit: ImageFit = .fill, focus: Point = .center, background: RGBAColor = .black) {
        self.source = source
        self.blockSize = min(max(blockSize, Self.blockRange.lowerBound), Self.blockRange.upperBound)
        self.paletteSize = paletteSize.map { min(max($0, Self.paletteRange.lowerBound), Self.paletteRange.upperBound) }
        self.fit = fit
        self.focus = focus
        self.background = background
    }

    private enum CodingKeys: String, CodingKey { case source, blockSize, paletteSize, fit, focus, background }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paletteSize = try container.decodeIfPresent(Int.self, forKey: .paletteSize)
        if let paletteSize, !Self.paletteRange.contains(paletteSize) {
            throw DecodingError.dataCorruptedError(forKey: .paletteSize, in: container, debugDescription: "\(paletteSize) is outside \(Self.paletteRange)")
        }
        self.init(
            source: try container.decodeIfPresent(ImageReference.self, forKey: .source),
            blockSize: try container.decodeBoundedIfPresent(Int.self, forKey: .blockSize, in: Self.blockRange, default: 16),
            paletteSize: paletteSize,
            fit: try container.decodeIfPresent(ImageFit.self, forKey: .fit) ?? .fill,
            focus: try container.decodeIfPresent(Point.self, forKey: .focus) ?? .center,
            background: try container.decodeIfPresent(RGBAColor.self, forKey: .background) ?? .black
        )
    }
}

/// The dither lab's algorithms.
public enum DitherMode: String, Codable, CaseIterable, Hashable, Sendable {
    case bayer2, bayer4, bayer8, floydSteinberg, blueNoise, halftone, ascii

    public var title: String {
        switch self {
        case .bayer2: "Bayer 2"
        case .bayer4: "Bayer 4"
        case .bayer8: "Bayer 8"
        case .floydSteinberg: "Floyd–Steinberg"
        case .blueNoise: "Blue noise"
        case .halftone: "Halftone"
        case .ascii: "ASCII"
        }
    }

    /// Halftone and ASCII draw a glyph per cell and need a larger cell.
    public var isGlyphMode: Bool { self == .halftone || self == .ascii }

    /// The cell range: 1–8 pixels for the point dithers, 4–32 for glyphs.
    public var cellRange: ClosedRange<Int> { isGlyphMode ? 4...32 : 1...8 }
}

public struct DitherParameters: Codable, Hashable, Sendable {
    public static let paletteRange = 3...16

    public var source: ImageReference?
    public var mode: DitherMode
    /// The pixel size of one dither cell (a point dither), or of one glyph.
    public var cell: Int
    /// Nil: two colors, ink on paper; a count: a reduced palette derived
    /// from the image (median cut), dithered between its entries.
    public var paletteSize: Int?
    public var ink: RGBAColor
    public var paper: RGBAColor
    public var fit: ImageFit
    public var focus: Point
    /// Behind a fitted image, and the whole render without a source.
    public var background: RGBAColor

    public init(
        source: ImageReference?, mode: DitherMode = .floydSteinberg, cell: Int = 2, paletteSize: Int? = nil,
        ink: RGBAColor = .white, paper: RGBAColor = .black, fit: ImageFit = .fill, focus: Point = .center, background: RGBAColor? = nil
    ) {
        self.source = source
        self.mode = mode
        self.cell = min(max(cell, mode.cellRange.lowerBound), mode.cellRange.upperBound)
        self.paletteSize = paletteSize.map { min(max($0, Self.paletteRange.lowerBound), Self.paletteRange.upperBound) }
        self.ink = ink
        self.paper = paper
        self.fit = fit
        self.focus = focus
        self.background = background ?? paper
    }

    private enum CodingKeys: String, CodingKey { case source, mode, cell, paletteSize, ink, paper, fit, focus, background }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decodeIfPresent(DitherMode.self, forKey: .mode) ?? .floydSteinberg
        let paletteSize = try container.decodeIfPresent(Int.self, forKey: .paletteSize)
        if let paletteSize, !Self.paletteRange.contains(paletteSize) {
            throw DecodingError.dataCorruptedError(forKey: .paletteSize, in: container, debugDescription: "\(paletteSize) is outside \(Self.paletteRange)")
        }
        self.init(
            source: try container.decodeIfPresent(ImageReference.self, forKey: .source),
            mode: mode,
            cell: try container.decodeBoundedIfPresent(Int.self, forKey: .cell, in: mode.cellRange, default: 2),
            paletteSize: paletteSize,
            ink: try container.decodeIfPresent(RGBAColor.self, forKey: .ink) ?? .white,
            paper: try container.decodeIfPresent(RGBAColor.self, forKey: .paper) ?? .black,
            fit: try container.decodeIfPresent(ImageFit.self, forKey: .fit) ?? .fill,
            focus: try container.decodeIfPresent(Point.self, forKey: .focus) ?? .center,
            background: try container.decodeIfPresent(RGBAColor.self, forKey: .background)
        )
    }
}
