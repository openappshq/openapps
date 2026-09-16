import Foundation

/// A parameter the user pinned in the panel: Shuffle keeps its value from
/// the current document. Document-wide pins (the palette, the seed, a
/// finish, the composition, the pair) apply to any shuffle; a pin on a
/// generator's own parameter keeps that generator as well, so the value
/// has somewhere to land.
public enum ParameterPin: String, Codable, CaseIterable, Hashable, Sendable {
    case generator, palette, seed, grain, topShade, tint, duotone, gradientMap, composition, pair
    case gradientShape, gradientAngle, gradientCenter, gradientBlend
    case meshGrid, meshJitter, meshSoftness
    case patternKind, patternScale, patternAngle
    case pixelizeBlock, pixelizePalette
    case ditherMode, ditherCell, ditherPalette
    /// Fill / fit / stretch, shared by pixelize and dither.
    case framing

    public var title: String {
        switch self {
        case .generator: "Generator"
        case .palette: "Palette"
        case .seed: "Seed"
        case .grain: "Grain"
        case .topShade: "Top shade"
        case .tint: "Tint"
        case .duotone: "Duotone"
        case .gradientMap: "Gradient map"
        case .composition: "Notch"
        case .pair: "Pair"
        case .gradientShape: "Shape"
        case .gradientAngle: "Angle"
        case .gradientCenter: "Center"
        case .gradientBlend: "Blend"
        case .meshGrid: "Grid"
        case .meshJitter: "Jitter"
        case .meshSoftness: "Softness"
        case .patternKind: "Pattern"
        case .patternScale: "Scale"
        case .patternAngle: "Angle"
        case .pixelizeBlock: "Block"
        case .pixelizePalette: "Colors"
        case .ditherMode: "Mode"
        case .ditherCell: "Cell"
        case .ditherPalette: "Colors"
        case .framing: "Framing"
        }
    }

    /// The generator the parameter belongs to; nil for a document-wide one.
    public var generatorKind: GeneratorKind? {
        switch self {
        case .generator, .palette, .seed, .grain, .topShade, .tint, .duotone, .gradientMap, .composition, .pair: nil
        case .gradientShape, .gradientAngle, .gradientCenter, .gradientBlend: .gradient
        case .meshGrid, .meshJitter, .meshSoftness: .mesh
        case .patternKind, .patternScale, .patternAngle: .pattern
        case .pixelizeBlock, .pixelizePalette: .pixelize
        case .ditherMode, .ditherCell, .ditherPalette: .dither
        // Framing belongs to both image generators: it keeps whichever
        // of them the document has.
        case .framing: nil
        }
    }
}

/// The pins as a set, with the one operation Shuffle needs.
public struct PinnedParameters: Hashable, Codable, Sendable {
    public var pins: Set<ParameterPin>

    public init(_ pins: Set<ParameterPin> = []) {
        self.pins = pins
    }

    public var isEmpty: Bool { pins.isEmpty }

    public func contains(_ pin: ParameterPin) -> Bool { pins.contains(pin) }

    public mutating func toggle(_ pin: ParameterPin) {
        if pins.contains(pin) { pins.remove(pin) } else { pins.insert(pin) }
    }

    /// Whether the pins keep the current document's generator: the
    /// generator pin itself, a pin on one of that generator's parameters,
    /// or the framing pin on an image generator.
    public func keepsGenerator(of current: Wallpaper) -> Bool {
        let kind = current.generator.kind
        if pins.contains(.generator) { return true }
        if pins.contains(.framing), kind.needsSource { return true }
        return pins.contains { $0.generatorKind == kind }
    }

    /// The candidate with every pinned value copied over from the current
    /// document, side by side: the light generator's pinned values into
    /// the candidate's light side and, where the current dark side was
    /// edited by hand, its pinned values into a dark side of its own (the
    /// candidate's derived dark side, with the same values carried), so a
    /// jitter pinned while editing the dark side survives as that side's
    /// jitter. Nothing else about the candidate changes: a shuffle with
    /// the palette pinned is a new document in the same colors.
    public func carry(from current: Wallpaper, into candidate: Wallpaper) -> Wallpaper {
        guard !pins.isEmpty else { return candidate }
        var out = candidate
        if keepsGenerator(of: current), out.generator.kind != current.generator.kind {
            out.generator = .default(current.generator.kind, colors: out.generator.colors, source: current.generator.source)
        }
        if pins.contains(.seed) { out.seed = current.seed }
        if pins.contains(.grain) { out.grain = current.grain }
        if pins.contains(.topShade) { out.finish.topShade = current.finish.topShade }
        if pins.contains(.tint) { out.finish.tint = current.finish.tint }
        if pins.contains(.duotone) { out.finish.duotone = current.finish.duotone }
        if pins.contains(.gradientMap) { out.finish.gradientMap = current.finish.gradientMap }
        if pins.contains(.composition) { out.composition = current.composition }
        if pins.contains(.pair) { out.pair = current.pair }
        out.generator = carry(from: current.generator, into: out.generator)
        if let dark = current.darkGenerator {
            // The candidate's dark side is derived from its (carried) light
            // side; the current dark side's own pinned values go over it.
            let derived = out.darkGenerator ?? out.generator.darkened()
            let carried = carry(from: dark, into: derived)
            out.darkGenerator = carried == derived && out.darkGenerator == nil ? nil : carried
        }
        return out
    }

    /// One side: the palette and the generator's own parameters.
    private func carry(from current: Generator, into candidate: Generator) -> Generator {
        var out = candidate
        if pins.contains(.palette) { out = out.withPalette(current.colors) }
        return carryParameters(from: current, into: out)
    }

    private func carryParameters(from current: Generator, into candidate: Generator) -> Generator {
        switch (current, candidate) {
        case (.gradient(let from), .gradient(var to)):
            if pins.contains(.gradientShape) { to.kind = from.kind }
            if pins.contains(.gradientAngle) { to.angle = from.angle }
            if pins.contains(.gradientCenter) { to.center = from.center }
            if pins.contains(.gradientBlend) { to.interpolation = from.interpolation }
            return .gradient(to)
        case (.mesh(let from), .mesh(var to)):
            if pins.contains(.meshGrid) { to.columns = from.columns; to.rows = from.rows }
            if pins.contains(.meshJitter) { to.jitter = from.jitter }
            if pins.contains(.meshSoftness) { to.softness = from.softness }
            return .mesh(to)
        case (.pattern(let from), .pattern(var to)):
            if pins.contains(.patternKind) { to.kind = from.kind }
            if pins.contains(.patternScale) { to.scale = from.scale }
            if pins.contains(.patternAngle) { to.angle = from.angle }
            return .pattern(to)
        case (.pixelize(let from), .pixelize(var to)):
            if pins.contains(.pixelizeBlock) { to.blockSize = from.blockSize }
            if pins.contains(.pixelizePalette) { to.paletteSize = from.paletteSize }
            if pins.contains(.framing) { to.fit = from.fit; to.focus = from.focus }
            return .pixelize(to)
        case (.dither(let from), .dither(var to)):
            if pins.contains(.ditherMode) { to.mode = from.mode; to.cell = min(max(to.cell, from.mode.cellRange.lowerBound), from.mode.cellRange.upperBound) }
            if pins.contains(.ditherCell) { to.cell = min(max(from.cell, to.mode.cellRange.lowerBound), to.mode.cellRange.upperBound) }
            if pins.contains(.ditherPalette) { to.paletteSize = from.paletteSize }
            if pins.contains(.framing) { to.fit = from.fit; to.focus = from.focus }
            return .dither(to)
        default:
            return candidate
        }
    }
}
