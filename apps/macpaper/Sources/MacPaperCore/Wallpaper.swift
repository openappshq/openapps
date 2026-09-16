import Foundation

/// A wallpaper is a document, not an image: a generator, its parameters, a
/// seed and a grain amount. The same document renders the same pixels at
/// the same size on every Mac; a favorite is a document, and renders again
/// for any display.
///
/// JSON: `{"version":1,"generator":{"type":"gradient",…},"seed":"…","grain":0.1}`.
/// The seed is a decimal string so it survives JSON parsers that round
/// 64-bit integers.
public struct Wallpaper: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var generator: Generator
    public var seed: UInt64
    /// Film grain, 0…1, a seeded monochrome finish on every generator.
    public var grain: Double

    public init(generator: Generator, seed: UInt64, grain: Double = 0) {
        self.generator = generator
        self.seed = seed
        self.grain = min(max(grain, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case version, generator, seed, grain
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
        grain = min(max(try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0, 0), 1)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(generator, forKey: .generator)
        try container.encode(String(seed), forKey: .seed)
        try container.encode(grain, forKey: .grain)
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

    /// The document a fresh install starts with: a seeded gradient, never
    /// applied on its own.
    public static let starter = Wallpaper(
        generator: .gradient(GradientParameters(
            kind: .linear, angle: 135,
            stops: [ColorStop(position: 0, color: RGBAColor(hex: 0xFF7A2F)), ColorStop(position: 0.55, color: RGBAColor(hex: 0xF3A0DC)), ColorStop(position: 1, color: RGBAColor(hex: 0x304BFF))]
        )),
        seed: 20_260_916, grain: 0.08
    )

    /// A random document for Shuffle: a random generator (never pixelize,
    /// which needs a source image), parameters from the seed.
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
            return Wallpaper(generator: .gradient(GradientParameters(kind: gradientKind, angle: angle, center: Point(x: generator.nextDouble(in: 0.3...0.7), y: generator.nextDouble(in: 0.3...0.7)), stops: stops)), seed: seed, grain: grain)
        case .mesh:
            return Wallpaper(generator: .mesh(MeshParameters(columns: 2 + Int(generator.next() % 3), rows: 2 + Int(generator.next() % 3), colors: Array(palette.prefix(3 + Int(generator.next() % 2))), jitter: generator.nextDouble(in: 0.2...0.8), softness: generator.nextDouble(in: 0.3...0.8))), seed: seed, grain: grain)
        case .pattern:
            let kinds = PatternKind.allCases
            let patternKind = kinds[Int(generator.next() % UInt64(kinds.count))]
            return Wallpaper(generator: .pattern(PatternParameters(kind: patternKind, foreground: palette[1], background: palette[0], scale: generator.nextDouble(in: 24...96), angle: Double(Int(generator.next() % 4)) * 45)), seed: seed, grain: grain)
        case .solid:
            return Wallpaper(generator: .solid(SolidParameters(color: palette[0])), seed: seed, grain: max(grain, 0.06))
        case .pixelize:
            // Not reachable: `shuffleable` leaves it out.
            return starter.reseeded(seed)
        }
    }
}

// MARK: - Generators

/// Which generator a document uses; the panel's segmented control.
public enum GeneratorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case gradient, mesh, pattern, solid, pixelize

    public var title: String {
        switch self {
        case .gradient: "Gradient"
        case .mesh: "Mesh"
        case .pattern: "Pattern"
        case .solid: "Solid"
        case .pixelize: "Pixelize"
        }
    }

    /// The generators Shuffle can make from nothing.
    public static let shuffleable: [GeneratorKind] = [.gradient, .mesh, .pattern, .solid]
}

/// The generator and its parameters. JSON carries a `type` discriminator
/// beside the parameters: `{"type":"gradient","kind":"linear",…}`.
public enum Generator: Hashable, Sendable {
    case gradient(GradientParameters)
    case mesh(MeshParameters)
    case pattern(PatternParameters)
    case solid(SolidParameters)
    case pixelize(PixelizeParameters)

    public var kind: GeneratorKind {
        switch self {
        case .gradient: .gradient
        case .mesh: .mesh
        case .pattern: .pattern
        case .solid: .solid
        case .pixelize: .pixelize
        }
    }

    /// The default parameters when the user switches to a generator,
    /// carrying the colors of the current one where that makes sense.
    public static func `default`(_ kind: GeneratorKind, colors: [RGBAColor]) -> Generator {
        let palette = colors.isEmpty ? Palettes.all[0] : colors
        switch kind {
        case .gradient:
            let count = min(max(palette.count, 2), 6)
            let stops = (0..<count).map { i in ColorStop(position: Double(i) / Double(count - 1), color: palette[i % palette.count]) }
            return .gradient(GradientParameters(kind: .linear, angle: 135, stops: stops))
        case .mesh:
            return .mesh(MeshParameters(columns: 3, rows: 3, colors: Array(palette.prefix(6)), jitter: 0.5, softness: 0.5))
        case .pattern:
            return .pattern(PatternParameters(kind: .dots, foreground: palette.count > 1 ? palette[1] : .white, background: palette[0], scale: 48, angle: 0))
        case .solid:
            return .solid(SolidParameters(color: palette[0]))
        case .pixelize:
            return .pixelize(PixelizeParameters(source: nil, blockSize: 16, paletteSize: nil, fit: .fill, background: palette[0]))
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

public struct GradientParameters: Codable, Hashable, Sendable {
    public static let stopRange = 2...6

    public var kind: GradientKind
    /// Degrees. Linear: 0 runs left to right, 90 top to bottom. Conic: where
    /// the first stop starts, clockwise from the right.
    public var angle: Double
    /// Radial and conic center.
    public var center: Point
    public var stops: [ColorStop]

    public init(kind: GradientKind, angle: Double = 135, center: Point = .center, stops: [ColorStop]) {
        self.kind = kind
        self.angle = angle
        self.center = center
        self.stops = stops
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
}

public struct SolidParameters: Codable, Hashable, Sendable {
    public var color: RGBAColor

    public init(color: RGBAColor) {
        self.color = color
    }
}

/// How an imported image is placed on a display of another aspect.
public enum ImageFit: String, Codable, CaseIterable, Hashable, Sendable {
    /// Scaled to cover the display, cropped at the edges.
    case fill
    /// Scaled to fit inside, the rest in the background color.
    case fit

    public var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        }
    }
}

/// A document's reference to an imported image: the file name under the
/// app's `imports/` folder, plus the content hash it was stored under, so
/// a favorite made on one Mac says what it needs on another.
public struct ImageReference: Codable, Hashable, Sendable {
    public var fileName: String
    public var contentHash: String

    public init(fileName: String, contentHash: String) {
        self.fileName = fileName
        self.contentHash = contentHash
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
    /// Behind a fitted image, and the whole render without a source.
    public var background: RGBAColor

    public init(source: ImageReference?, blockSize: Int = 16, paletteSize: Int? = nil, fit: ImageFit = .fill, background: RGBAColor = .black) {
        self.source = source
        self.blockSize = min(max(blockSize, Self.blockRange.lowerBound), Self.blockRange.upperBound)
        self.paletteSize = paletteSize.map { min(max($0, Self.paletteRange.lowerBound), Self.paletteRange.upperBound) }
        self.fit = fit
        self.background = background
    }
}
