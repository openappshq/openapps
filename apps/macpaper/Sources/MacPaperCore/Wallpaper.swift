import Foundation

/// A wallpaper is a document, not an image: a generator, its parameters, a
/// seed, the finishes, the pair and the composition. The same document
/// renders the same pixels at the same size on every Mac; a favorite is a
/// document, and renders again for any display.
///
/// JSON, version 2: `{"version":2,"generator":{"type":"gradient",…},"seed":"…",
/// "grain":0.1,"finish":{…},"pair":{"mode":"still"},"composition":"none"}`.
/// Version-1 documents (generator, seed, grain) decode with the defaults.
/// The seed is a decimal string so it survives JSON parsers that round
/// 64-bit integers.
public struct Wallpaper: Codable, Hashable, Sendable {
    public static let currentVersion = 2

    public var generator: Generator
    public var seed: UInt64
    /// Film grain, 0…1, a seeded monochrome finish on every generator.
    public var grain: Double
    /// Tint, duotone, gradient map and the top shade.
    public var finish: Finish
    /// Still, a light/dark pair, or a time-of-day set.
    public var pair: PairMode
    /// The dark side, when the user edited it; nil derives it from the
    /// light side (`Generator.darkened`).
    public var darkGenerator: Generator?
    /// How the render composes around the notch.
    public var composition: Composition

    public init(
        generator: Generator, seed: UInt64, grain: Double = 0, finish: Finish = Finish(), pair: PairMode = .still,
        darkGenerator: Generator? = nil, composition: Composition = .none
    ) {
        self.generator = generator
        self.seed = seed
        self.grain = min(max(grain, 0), 1)
        self.finish = finish
        self.pair = pair
        self.darkGenerator = darkGenerator
        self.composition = composition
    }

    private enum CodingKeys: String, CodingKey {
        case version, generator, seed, grain, finish, pair, darkGenerator, composition
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

    /// Whether the dark side was edited by hand (nil derives it).
    public var hasCustomDark: Bool { darkGenerator != nil }

    /// Every finish off, grain off: the render is the generator's own pixels.
    public var isPlain: Bool { grain == 0 && finish.isEmpty }

    /// `#000000` with nothing on top: exact zeros on every pixel.
    public var isTrueBlack: Bool {
        if case .solid(let p) = generator, p.color == .black { return isPlain && composition != .pill }
        return false
    }

    /// The document a fresh install starts with: a seeded gradient, never
    /// applied on its own.
    public static let starter = Wallpaper(
        generator: .gradient(GradientParameters(
            kind: .linear, angle: 135,
            stops: [ColorStop(position: 0, color: RGBAColor(hex: 0xFF7A2F)), ColorStop(position: 0.55, color: RGBAColor(hex: 0xF3A0DC)), ColorStop(position: 1, color: RGBAColor(hex: 0x304BFF))],
            interpolation: .oklch
        )),
        seed: 20_260_916, grain: 0.08
    )

    /// True black: `#000000`, nothing else.
    public static let trueBlack = Wallpaper(generator: .solid(SolidParameters(color: .black)), seed: 0)

    /// A random document for Shuffle: a random generator (never pixelize or
    /// dither, which need a source image), parameters from the seed,
    /// gradients interpolated in OKLCH.
    public static func random(using generator: inout SeededGenerator) -> Wallpaper {
        let seed = generator.next()
        let kind = GeneratorKind.shuffleable[Int(generator.next() % UInt64(GeneratorKind.shuffleable.count))]
        let palette = Palettes.all[Int(generator.next() % UInt64(Palettes.all.count))].shuffled(using: &generator)
        let grain = generator.nextUnit() < 0.5 ? 0 : generator.nextDouble(in: 0.04...0.18)
        switch kind {
        case .gradient:
            let kinds = GradientKind.allCases
            let gradientKind = kinds[Int(generator.next() % UInt64(kinds.count))]
            let count = 2 + Int(generator.next() % 3)
            let stops = (0..<count).map { i in ColorStop(position: Double(i) / Double(count - 1), color: palette[i % palette.count]) }
            let angle = Double(Int(generator.next() % 8)) * 45
            return Wallpaper(generator: .gradient(GradientParameters(kind: gradientKind, angle: angle, center: Point(x: generator.nextDouble(in: 0.3...0.7), y: generator.nextDouble(in: 0.3...0.7)), stops: stops, interpolation: .oklch)), seed: seed, grain: grain)
        case .mesh:
            return Wallpaper(generator: .mesh(MeshParameters(columns: 2 + Int(generator.next() % 3), rows: 2 + Int(generator.next() % 3), colors: Array(palette.prefix(3 + Int(generator.next() % 2))), jitter: generator.nextDouble(in: 0.2...0.8), softness: generator.nextDouble(in: 0.3...0.8))), seed: seed, grain: grain)
        case .pattern:
            let kinds = PatternKind.allCases
            let patternKind = kinds[Int(generator.next() % UInt64(kinds.count))]
            return Wallpaper(generator: .pattern(PatternParameters(kind: patternKind, foreground: palette[1], background: palette[0], scale: generator.nextDouble(in: 24...96), angle: Double(Int(generator.next() % 4)) * 45)), seed: seed, grain: grain)
        case .solid:
            return Wallpaper(generator: .solid(SolidParameters(color: palette[0])), seed: seed, grain: max(grain, 0.06))
        case .pixelize, .dither:
            // Not reachable: `shuffleable` leaves them out.
            return starter.reseeded(seed)
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

/// The finishes after the generator, in the order they apply: tint,
/// duotone, gradient map, (grain, on the document), top shade.
public struct Finish: Codable, Hashable, Sendable {
    public var tint: Tint?
    public var duotone: Duotone?
    /// 2–6 stops over luminance, 0 = darkest.
    public var gradientMap: [ColorStop]?
    /// A darkening of the menu-bar strip, 0…1, so its text reads.
    public var topShade: Double

    public init(tint: Tint? = nil, duotone: Duotone? = nil, gradientMap: [ColorStop]? = nil, topShade: Double = 0) {
        self.tint = tint
        self.duotone = duotone
        self.gradientMap = gradientMap
        self.topShade = min(max(topShade, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case tint, duotone, gradientMap, topShade }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tint = try container.decodeIfPresent(Tint.self, forKey: .tint)
        duotone = try container.decodeIfPresent(Duotone.self, forKey: .duotone)
        gradientMap = try container.decodeIfPresent([ColorStop].self, forKey: .gradientMap)
        if let map = gradientMap, !GradientParameters.stopRange.contains(map.count) {
            throw DecodingError.dataCorruptedError(forKey: .gradientMap, in: container, debugDescription: "A gradient map has \(GradientParameters.stopRange) stops, not \(map.count)")
        }
        topShade = try container.decodeFiniteIfPresent(Double.self, forKey: .topShade, in: 0...1, default: 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tint, forKey: .tint)
        try container.encodeIfPresent(duotone, forKey: .duotone)
        try container.encodeIfPresent(gradientMap, forKey: .gradientMap)
        try container.encode(topShade, forKey: .topShade)
    }

    public var isEmpty: Bool { tint == nil && duotone == nil && gradientMap == nil && topShade == 0 }
}

// MARK: - Generators

/// Which generator a document uses; the panel's segmented control.
public enum GeneratorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case gradient, mesh, pattern, solid, pixelize, dither

    public var title: String {
        switch self {
        case .gradient: "Gradient"
        case .mesh: "Mesh"
        case .pattern: "Pattern"
        case .solid: "Solid"
        case .pixelize: "Pixelize"
        case .dither: "Dither"
        }
    }

    /// The generators Shuffle can make from nothing.
    public static let shuffleable: [GeneratorKind] = [.gradient, .mesh, .pattern, .solid]

    /// The generators that work on an imported image.
    public var needsSource: Bool { self == .pixelize || self == .dither }
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

    public var kind: GeneratorKind {
        switch self {
        case .gradient: .gradient
        case .mesh: .mesh
        case .pattern: .pattern
        case .solid: .solid
        case .pixelize: .pixelize
        case .dither: .dither
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
        }
    }

    /// The dark side derived from the light one: every color's OKLCH
    /// lightness folded down (0 → 0.12, 1 → 0.47), hue and chroma kept
    /// (chroma capped so a bright color does not glow in the dark).
    public func darkened() -> Generator {
        recolored { color in
            var lch = OKLCH(color)
            lch.l = 0.12 + 0.35 * lch.l
            lch.c = min(lch.c, 0.12)
            return lch.color
        }
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
