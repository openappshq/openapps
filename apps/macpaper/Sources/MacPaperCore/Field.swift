import Foundation

/// The pixel-field families: authored looks on one sampled-field engine
/// (FieldEngine.swift). Each declares its knobs with ranges and defaults;
/// a document carries only values for the knobs its family declares.
public enum FieldFamily: String, Codable, CaseIterable, Hashable, Sendable {
    /// Interference atlas: a radial and a linear wave beat on a pixel grid
    /// (or two twisted lattices, or two woven grids), faded from an anchor.
    case interference
    /// Contour relief: a warped noise height cut into shifted terraces,
    /// their rims lit from one side like cut paper.
    case relief
    /// Pixel archipelago: domain-warped noise above a sea level, bands of
    /// terrain, dithered shores, no crumbs.
    case islands
    /// Resonance plate: a Chladni-inspired standing-wave pair; grains
    /// gather along the nodal lines inside an aperture.
    case plate
    /// Woven circuit: Truchet quarter-circle ribbons that connect across
    /// tiles, scored for long paths.
    case circuit
    /// Memory sky: a horizon, two ridges, a cropped sun and haze, diffused
    /// into large cells by serpentine error diffusion.
    case sky

    public var title: String {
        switch self {
        case .interference: "Moiré"
        case .relief: "Relief"
        case .islands: "Islands"
        case .plate: "Plate"
        case .circuit: "Circuit"
        case .sky: "Sky"
        }
    }

    /// One line under the family's name in the panel.
    public var summary: String {
        switch self {
        case .interference: "A radial and a linear wave beat on the pixel grid."
        case .relief: "Warped noise cut into terraces, rims lit like cut paper."
        case .islands: "An archipelago above a sea level, shores dithered."
        case .plate: "Chladni nodal lines gathering grains inside an aperture."
        case .circuit: "Truchet ribbons joined into paths across tiles."
        case .sky: "A horizon, two ridges and a cropped sun in large cells."
        }
    }

    /// The SF Symbol the panel's lists use.
    public var symbolName: String {
        switch self {
        case .interference: "circle.circle"
        case .relief: "mountain.2"
        case .islands: "water.waves"
        case .plate: "sparkles"
        case .circuit: "point.3.connected.trianglepath.dotted"
        case .sky: "sun.horizon"
        }
    }

    /// The tone counts the family is designed for (the palette's size).
    public var toneRange: ClosedRange<Int> {
        switch self {
        case .interference: 2...4
        case .relief: 4...6
        case .islands: 3...5
        case .plate: 2...3
        case .circuit: 2...4
        case .sky: 3...5
        }
    }

    /// The family's knobs, in the order the panel shows them. The shared
    /// grid knobs (cell size, dither, tone steps) come last.
    public var knobs: [KnobSpec] {
        let common: [KnobSpec] = [
            KnobSpec(.cellSize, 4...64, 12, step: 1),
            KnobSpec(.dither, choices: ToneDitherMode.allCases.map(\.title), ditherDefault.rawValue),
            KnobSpec(.depth, 0...1, 0.35),
            KnobSpec(.oklab, toggle: true),
        ]
        switch self {
        case .interference:
            return [
                KnobSpec(.mode, choices: ["Atlas", "Lattice", "Weave"], 0),
                KnobSpec(.repeatX, 2...24, 9), KnobSpec(.repeatY, 2...24, 7),
                KnobSpec(.twist, -90...90, 12),
                KnobSpec(.anchorX, -0.2...1.2, 0.62), KnobSpec(.anchorY, -0.2...1.2, 0.38),
                KnobSpec(.reach, 0.2...1, 0.7), KnobSpec(.offset, 0...1, 0.25), KnobSpec(.balance, 0.2...0.8, 0.5),
                KnobSpec(.toneSteps, 2...8, 4, step: 1), KnobSpec(.reflect, toggle: false),
            ] + common
        case .relief:
            return [
                KnobSpec(.scale, 1...5, 2.2), KnobSpec(.warp, 0...0.25, 0.08),
                KnobSpec(.toneSteps, 4...9, 6, step: 1), KnobSpec(.offset, 0...1, 0.4),
                KnobSpec(.angle, 0...360, 135), KnobSpec(.rim, 0...1, 0.5), KnobSpec(.relief, 0...1, 0.4),
                KnobSpec(.anchorX, 0...1, 0.6), KnobSpec(.anchorY, 0...1, 0.45), KnobSpec(.reach, 0.2...0.9, 0.5), KnobSpec(.focal, 0...1, 0.5),
            ] + common
        case .islands:
            return [
                KnobSpec(.scale, 1...4, 2), KnobSpec(.warp, 0.03...0.22, 0.12), KnobSpec(.seaLevel, 0.3...0.7, 0.5),
                KnobSpec(.toneSteps, 3...5, 4, step: 1), KnobSpec(.roughness, 0.25...0.6, 0.42), KnobSpec(.shore, 1...4, 2, step: 1),
                KnobSpec(.focal, 0...0.35, 0.2), KnobSpec(.anchorX, 0...1, 0.55), KnobSpec(.anchorY, 0...1, 0.5),
            ] + common
        case .plate:
            return [
                KnobSpec(.modeM, 2...8, 3, step: 1), KnobSpec(.modeN, 1...7, 5, step: 1), KnobSpec(.balance, 0.75...1.25, 1),
                KnobSpec(.nodalWidth, 0.02...0.12, 0.05), KnobSpec(.angle, 0...90, 0), KnobSpec(.reach, 0.35...0.9, 0.6),
                KnobSpec(.density, 0.1...0.45, 0.25), KnobSpec(.toneSteps, 2...3, 3, step: 1),
                KnobSpec(.anchorX, 0...1, 0.5), KnobSpec(.anchorY, 0...1, 0.5),
            ] + common
        case .circuit:
            return [
                KnobSpec(.scale, 8...64, 32, step: 1), KnobSpec(.ribbon, 0.14...0.36, 0.24), KnobSpec(.bias, 0.2...0.8, 0.5),
                KnobSpec(.biasScale, 1...4, 2), KnobSpec(.loops, 0...1, 0.3),
                KnobSpec(.accent, 0.03...0.15, 0.08), KnobSpec(.toneSteps, 2...4, 3, step: 1),
            ] + common
        case .sky:
            return [
                KnobSpec(.horizon, 0.28...0.72, 0.58), KnobSpec(.sunX, 0.15...0.85, 0.68), KnobSpec(.sunRadius, 0.08...0.28, 0.16),
                KnobSpec(.haze, 0.04...0.2, 0.1), KnobSpec(.ridge, 0.01...0.08, 0.04), KnobSpec(.clouds, 0.05...0.25, 0.1),
                KnobSpec(.diffusion, 0.55...1, 0.85), KnobSpec(.toneSteps, 3...5, 4, step: 1),
            ] + common
        }
    }

    /// The dither the family is designed around: Bayer for designed pixel
    /// rhythms, blue noise for quiet material, serpentine diffusion for the
    /// sky, none for crisp contour fills.
    public var ditherDefault: ToneDitherMode {
        switch self {
        case .interference: .bayer
        case .relief: .none
        case .islands: .blueNoise
        case .plate: .blueNoise
        case .circuit: .bayer
        case .sky: .diffusion
        }
    }

    public func spec(_ key: ParameterKey) -> KnobSpec? {
        knobs.first { $0.key == key }
    }

    /// The knob table by key, built once per family.
    static let specTables: [FieldFamily: [ParameterKey: KnobSpec]] = Dictionary(uniqueKeysWithValues: allCases.map { family in
        (family, Dictionary(uniqueKeysWithValues: family.knobs.map { ($0.key, $0) }))
    })
}

/// How a field's fractional tone residual becomes a whole tone per cell.
public enum ToneDitherMode: Int, CaseIterable, Codable, Hashable, Sendable {
    /// The nearer tone.
    case none
    /// The 8×8 Bayer threshold: a designed pixel rhythm.
    case bayer
    /// The 64×64 blue-noise tile: quiet grain.
    case blueNoise
    /// Serpentine Floyd–Steinberg on the scalar residual: large-cell
    /// error diffusion.
    case diffusion

    public var title: String {
        switch self {
        case .none: "None"
        case .bayer: "Bayer"
        case .blueNoise: "Blue noise"
        case .diffusion: "Diffusion"
        }
    }
}

/// One knob of a field family: its key, range, default, and how the panel
/// shows it (a slider with a step, a toggle, or a choice).
public struct KnobSpec: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        case slider
        case toggle
        case choice([String])
    }

    public let key: ParameterKey
    public let range: ClosedRange<Double>
    public let `default`: Double
    /// The slider's step: 1 for a whole number, 0 for continuous.
    public let step: Double
    public let style: Style

    public init(_ key: ParameterKey, _ range: ClosedRange<Double>, _ defaultValue: Double, step: Double = 0) {
        self.key = key
        self.range = range
        self.default = defaultValue
        self.step = step
        self.style = .slider
    }

    public init(_ key: ParameterKey, toggle defaultValue: Bool) {
        self.key = key
        self.range = 0...1
        self.default = defaultValue ? 1 : 0
        self.step = 1
        self.style = .toggle
    }

    public init(_ key: ParameterKey, choices: [String], _ defaultValue: Int) {
        self.key = key
        self.range = 0...Double(max(0, choices.count - 1))
        self.default = Double(defaultValue)
        self.step = 1
        self.style = .choice(choices)
    }

    public var title: String { key.title }

    public var isWhole: Bool { step == 1 }

    /// The value clamped into the range, rounded when whole.
    public func clamped(_ value: Double) -> Double {
        let v = min(max(value.isFinite ? value : self.default, range.lowerBound), range.upperBound)
        return isWhole ? v.rounded() : v
    }
}

/// A pixel field: a family, its ordered tones (ground first), and its
/// knob values. JSON: `{"type":"field","family":"interference",
/// "tones":["#…"],"knobs":{"twist":12,…}}`. Only declared knobs are
/// kept; an unknown knob is dropped, a value outside its range is refused.
public struct FieldParameters: Codable, Hashable, Sendable {
    public static let toneRange = 2...6

    public var family: FieldFamily
    /// Ground first, loudest last: always 2–6 distinct tones, whatever is
    /// assigned (one color becomes a ramp of itself, `Palettes.usable`).
    public var tones: [RGBAColor] {
        didSet { if !Self.isUsable(tones) { tones = Palettes.usable(tones) } }
    }
    public private(set) var values: [ParameterKey: Double]

    public init(family: FieldFamily, tones: [RGBAColor], values: [ParameterKey: Double] = [:]) {
        self.family = family
        self.tones = Self.isUsable(tones) ? tones : Palettes.usable(tones)
        self.values = [:]
        for (key, value) in values { self[key] = value }
    }

    /// 2–6 tones, no two the same byte for byte.
    static func isUsable(_ tones: [RGBAColor]) -> Bool {
        Self.toneRange.contains(tones.count) && Set(tones.map(\.hexString)).count == tones.count
    }

    /// The knob's value, or its default; a knob the family does not
    /// declare reads 0 and takes no value.
    public subscript(key: ParameterKey) -> Double {
        get { values[key] ?? family.spec(key)?.default ?? 0 }
        set {
            guard let spec = FieldFamily.specTables[family]?[key] else { return }
            let clamped = spec.clamped(newValue)
            if clamped == spec.default { values[key] = nil } else { values[key] = clamped }
        }
    }

    public func int(_ key: ParameterKey) -> Int { Int(self[key].rounded()) }
    public func bool(_ key: ParameterKey) -> Bool { self[key] >= 0.5 }

    public var cellSize: Int { max(1, int(.cellSize)) }
    public var toneSteps: Int { max(2, int(.toneSteps)) }
    public var ditherMode: ToneDitherMode { ToneDitherMode(rawValue: int(.dither)) ?? family.ditherDefault }

    /// The same field in another family: shared knobs keep their values,
    /// the rest take the new family's defaults.
    public func inFamily(_ other: FieldFamily) -> FieldParameters {
        FieldParameters(family: other, tones: tones, values: values)
    }

    private enum CodingKeys: String, CodingKey { case family, tones, knobs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let family = try container.decode(FieldFamily.self, forKey: .family)
        let tones = try container.decode([RGBAColor].self, forKey: .tones)
        guard Self.toneRange.contains(tones.count) else {
            throw DecodingError.dataCorruptedError(forKey: .tones, in: container, debugDescription: "A field has \(Self.toneRange) tones, not \(tones.count)")
        }
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .knobs) ?? [:]
        guard raw.count <= ParameterKey.allCases.count else {
            throw DecodingError.dataCorruptedError(forKey: .knobs, in: container, debugDescription: "Too many knobs")
        }
        var values: [ParameterKey: Double] = [:]
        for (name, value) in raw {
            guard let key = ParameterKey(rawValue: name), let spec = family.spec(key) else { continue }
            guard value.isFinite, spec.range.contains(value) else {
                throw DecodingError.dataCorruptedError(forKey: .knobs, in: container, debugDescription: "\(name) \(value) is outside \(spec.range)")
            }
            values[key] = value
        }
        self.init(family: family, tones: tones, values: values)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(family, forKey: .family)
        try container.encode(tones, forKey: .tones)
        var knobs: [String: Double] = [:]
        for (key, value) in values { knobs[key.rawValue] = value }
        if !knobs.isEmpty { try container.encode(knobs, forKey: .knobs) }
    }
}
