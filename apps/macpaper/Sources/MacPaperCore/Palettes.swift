import Foundation

/// A named set of two to five tones that read as one wallpaper, defined in
/// OKLCH so lightness steps are perceptual. The first tone is the ground
/// (the interference generator's level 0, a pattern's paper), the last is
/// the loudest accent; a generator that takes fewer colors uses them in
/// this order.
public struct Palette: Hashable, Sendable, Identifiable {
    public let name: String
    public let group: PaletteGroup
    public let tones: [RGBAColor]

    public var id: String { name }

    /// From OKLCH triples (l 0…1, c, h degrees); chroma outside the sRGB
    /// gamut is clipped, hue and lightness kept.
    init(_ name: String, _ group: PaletteGroup, _ lch: [(Double, Double, Double)]) {
        self.name = name
        self.group = group
        self.tones = lch.map { OKLCH(l: $0.0, c: $0.1, h: $0.2).color.snapped }
    }

    public init(name: String, group: PaletteGroup, tones: [RGBAColor]) {
        self.name = name
        self.group = group
        self.tones = tones
    }

    public var ground: RGBAColor { tones[0] }

    /// A document's own colors as a palette.
    public static func custom(_ tones: [RGBAColor]) -> Palette {
        Palette(name: Palettes.customName, group: .custom, tones: Palettes.usable(tones))
    }

    public var isCustom: Bool { group == .custom }

    /// The preset rule: the ground reads decisively — 7:1 against white
    /// text or 7:1 against black text — so no palette sits in the mid
    /// luminance where neither menu-bar text color reads and everything
    /// looks like mud; and the tones are visibly distinct (ΔE ≥ 0.05 in
    /// OKLab between every pair).
    public var passesPresetRule: Bool {
        groundReads(ground) && groundReads(Generator.solid(SolidParameters(color: ground)).darkened().colors[0]) && hasDistinctTones
    }

    public var hasDistinctTones: Bool {
        for i in tones.indices {
            for j in tones.indices where j > i && OKLCH.distance(tones[i], tones[j]) < 0.05 { return false }
        }
        return true
    }

    /// 7:1 (WCAG AAA) with white or with black.
    public func groundReads(_ color: RGBAColor) -> Bool {
        let y = color.luminance
        return 1.05 / (y + 0.05) >= 7 || (y + 0.05) / 0.05 >= 7
    }
}

/// Where a preset sits in the grid; `custom` is the user's own colors.
public enum PaletteGroup: String, CaseIterable, Codable, Hashable, Sendable {
    case circuit, cyber, blueprint, vapor, vga, magma, rust, signal, paper, sea, forest, dusk, custom

    /// The groups the grid shows.
    public static let presetGroups: [PaletteGroup] = allCases.filter { $0 != .custom }

    public var title: String {
        switch self {
        case .custom: "Custom"
        case .circuit: "Circuit"
        case .cyber: "Cyber"
        case .blueprint: "Blueprint"
        case .vapor: "Vapor"
        case .vga: "VGA"
        case .magma: "Magma"
        case .rust: "Rust"
        case .signal: "Signal"
        case .paper: "Paper"
        case .sea: "Sea"
        case .forest: "Forest"
        case .dusk: "Dusk"
        }
    }
}

/// The built-in palettes: the grid the panel shows, what Shuffle draws
/// from (never a random hue), and the names a recipe is called after.
public enum Palettes {
    /// The custom palette's name: a document whose colors match no preset.
    public static let customName = "Custom"

    public static let presets: [Palette] = [
        // Circuit: mint and phosphor on dark boards.
        Palette("Mint Circuit", .circuit, [(0.22, 0.04, 180), (0.55, 0.12, 165), (0.88, 0.14, 160)]),
        Palette("Board", .circuit, [(0.25, 0.05, 160), (0.72, 0.16, 150), (0.95, 0.06, 140)]),
        Palette("Phosphor", .circuit, [(0.15, 0.02, 150), (0.80, 0.22, 142)]),
        Palette("Terminal Amber", .circuit, [(0.16, 0.02, 70), (0.82, 0.16, 75)]),
        Palette("Sonar", .circuit, [(0.20, 0.05, 200), (0.60, 0.12, 195), (0.85, 0.10, 190), (0.96, 0.03, 190)]),
        // Cyber: near-black grounds, one or two loud lights.
        Palette("Neon Night", .cyber, [(0.12, 0.02, 290), (0.58, 0.25, 330), (0.85, 0.16, 195)]),
        Palette("Ultraviolet", .cyber, [(0.14, 0.05, 300), (0.45, 0.22, 300), (0.75, 0.20, 320), (0.93, 0.08, 330)]),
        Palette("Acid", .cyber, [(0.13, 0.01, 120), (0.90, 0.24, 120)]),
        Palette("Hologram", .cyber, [(0.18, 0.04, 260), (0.62, 0.16, 260), (0.78, 0.15, 200), (0.92, 0.12, 130)]),
        Palette("Laser", .cyber, [(0.10, 0.02, 20), (0.62, 0.25, 25), (0.95, 0.04, 60)]),
        Palette("Grid Blue", .cyber, [(0.15, 0.05, 250), (0.70, 0.20, 240)]),
        // Blueprint: drafting blues and paper.
        Palette("Blueprint", .blueprint, [(0.40, 0.15, 255), (0.95, 0.03, 240)]),
        Palette("Drafting", .blueprint, [(0.96, 0.02, 240), (0.40, 0.14, 255)]),
        Palette("Cyanotype", .blueprint, [(0.28, 0.10, 250), (0.58, 0.12, 235), (0.90, 0.05, 220)]),
        Palette("Graph Paper", .blueprint, [(0.97, 0.01, 90), (0.75, 0.06, 220), (0.35, 0.03, 250)]),
        Palette("Navy Chalk", .blueprint, [(0.24, 0.06, 265), (0.92, 0.02, 80)]),
        // Vapor: pinks, violets and a cold light.
        Palette("Vaporwave", .vapor, [(0.30, 0.10, 310), (0.72, 0.20, 340), (0.85, 0.12, 200), (0.95, 0.05, 100)]),
        Palette("Sunset Strip", .vapor, [(0.26, 0.08, 290), (0.62, 0.20, 15), (0.82, 0.17, 60)]),
        Palette("Miami", .vapor, [(0.20, 0.06, 280), (0.70, 0.22, 350), (0.88, 0.13, 180)]),
        Palette("Peach Ice", .vapor, [(0.94, 0.04, 50), (0.80, 0.12, 30), (0.60, 0.15, 340)]),
        Palette("Lavender Dusk", .vapor, [(0.30, 0.08, 300), (0.70, 0.10, 310), (0.92, 0.04, 320)]),
        // VGA: greys, warm and cold.
        Palette("VGA Gray", .vga, [(0.25, 0, 0), (0.50, 0, 0), (0.75, 0, 0), (0.95, 0, 0)]),
        Palette("Charcoal", .vga, [(0.16, 0, 0), (0.42, 0, 0), (0.72, 0, 0)]),
        Palette("Paper White", .vga, [(0.97, 0, 0), (0.80, 0, 0), (0.50, 0, 0), (0.20, 0, 0)]),
        Palette("Slate", .vga, [(0.28, 0.02, 250), (0.50, 0.02, 250), (0.72, 0.02, 250), (0.92, 0.01, 250)]),
        Palette("Ink Wash", .vga, [(0.18, 0.01, 260), (0.40, 0.02, 260), (0.85, 0.01, 80)]),
        // Magma: black through red to yellow.
        Palette("Magma", .magma, [(0.12, 0.02, 30), (0.45, 0.18, 30), (0.72, 0.19, 50), (0.92, 0.13, 90)]),
        Palette("Ember", .magma, [(0.16, 0.03, 40), (0.55, 0.20, 35), (0.85, 0.17, 80)]),
        Palette("Lava", .magma, [(0.10, 0.01, 0), (0.50, 0.22, 25), (0.88, 0.19, 95)]),
        Palette("Coal Fire", .magma, [(0.22, 0.02, 60), (0.68, 0.17, 55)]),
        Palette("Rose Heat", .magma, [(0.15, 0.03, 10), (0.62, 0.22, 5), (0.90, 0.08, 20)]),
        // Rust: earth, copper and clay.
        Palette("Rust", .rust, [(0.30, 0.06, 50), (0.55, 0.14, 45), (0.78, 0.12, 70)]),
        Palette("Copper", .rust, [(0.24, 0.04, 60), (0.62, 0.13, 60), (0.86, 0.09, 80)]),
        Palette("Clay", .rust, [(0.90, 0.05, 60), (0.68, 0.11, 45), (0.40, 0.08, 35)]),
        Palette("Terracotta", .rust, [(0.35, 0.08, 40), (0.70, 0.15, 45), (0.95, 0.04, 80)]),
        Palette("Oxide", .rust, [(0.20, 0.03, 30), (0.48, 0.12, 35), (0.70, 0.10, 75), (0.92, 0.05, 95)]),
        // Signal: bold, few, loud.
        Palette("Signal", .signal, [(0.15, 0.01, 0), (0.70, 0.20, 30), (0.90, 0.18, 95), (0.97, 0.01, 0)]),
        Palette("Hazard", .signal, [(0.13, 0.01, 90), (0.88, 0.18, 95)]),
        Palette("Primary", .signal, [(0.95, 0.01, 90), (0.55, 0.23, 260), (0.62, 0.22, 25), (0.88, 0.18, 95)]),
        Palette("Cobalt Flash", .signal, [(0.22, 0.08, 265), (0.60, 0.22, 262), (0.93, 0.03, 100)]),
        Palette("Racing", .signal, [(0.14, 0.02, 145), (0.60, 0.16, 145), (0.95, 0.02, 90)]),
        // Paper: light grounds, ink on top.
        Palette("Newsprint", .paper, [(0.94, 0.01, 90), (0.25, 0.01, 60)]),
        Palette("Cream Ink", .paper, [(0.96, 0.03, 85), (0.40, 0.06, 260)]),
        Palette("Risograph", .paper, [(0.95, 0.02, 80), (0.55, 0.20, 10), (0.55, 0.14, 230)]),
        Palette("Linen", .paper, [(0.93, 0.02, 70), (0.72, 0.05, 60), (0.45, 0.04, 40)]),
        Palette("Chalkboard", .paper, [(0.30, 0.04, 150), (0.93, 0.02, 90), (0.80, 0.12, 80)]),
        // Sea.
        Palette("Sea", .sea, [(0.28, 0.10, 255), (0.65, 0.15, 240), (0.85, 0.14, 200), (0.95, 0.06, 160)]),
        Palette("Deep Sea", .sea, [(0.14, 0.04, 240), (0.45, 0.12, 225), (0.75, 0.12, 195)]),
        Palette("Lagoon", .sea, [(0.90, 0.06, 190), (0.60, 0.13, 200), (0.35, 0.09, 230)]),
        Palette("Tide", .sea, [(0.20, 0.05, 220), (0.80, 0.10, 180)]),
        // Forest.
        Palette("Forest", .forest, [(0.24, 0.06, 150), (0.48, 0.12, 145), (0.85, 0.12, 135), (0.96, 0.03, 120)]),
        Palette("Moss", .forest, [(0.30, 0.05, 120), (0.62, 0.12, 110), (0.90, 0.08, 100)]),
        Palette("Pine", .forest, [(0.18, 0.03, 160), (0.55, 0.10, 155), (0.92, 0.03, 140)]),
        // Dusk.
        Palette("Dusk", .dusk, [(0.28, 0.08, 275), (0.55, 0.20, 270), (0.80, 0.10, 280), (0.95, 0.03, 290)]),
        Palette("Night Sky", .dusk, [(0.13, 0.03, 270), (0.40, 0.12, 280), (0.88, 0.06, 80)]),
        Palette("Twilight", .dusk, [(0.22, 0.06, 300), (0.55, 0.15, 20), (0.90, 0.10, 70)]),
    ]

    /// The presets' tones, in order: what the random documents and the
    /// generator defaults index.
    public static let all: [[RGBAColor]] = presets.map(\.tones)

    public static func preset(named name: String) -> Palette? {
        presets.first { $0.name == name }
    }

    public static func presets(in group: PaletteGroup) -> [Palette] {
        presets.filter { $0.group == group }
    }

    /// The preset whose tones a document's colors are — as a set, in any
    /// order, byte-exact; failing that, the first preset that holds all
    /// of them (a family may use two of a palette's four tones) — or nil:
    /// the name a recipe is called after.
    public static func preset(matching colors: [RGBAColor]) -> Palette? {
        let wanted = Set(colors.map(\.hexString))
        guard wanted.count >= 2 else { return nil }
        if let exact = presets.first(where: { Set($0.tones.map(\.hexString)) == wanted }) { return exact }
        return presets.first { wanted.isSubset(of: Set($0.tones.map(\.hexString))) }
    }

    /// The preset name for a document's colors, or "Custom".
    public static func name(for colors: [RGBAColor]) -> String {
        preset(matching: colors)?.name ?? customName
    }

    /// Colors a generator can take: at least two distinct tones, byte
    /// exact, at most six. One color (a photo of one hue, a solid) becomes
    /// a three-tone ramp of it — a darker step, the color, a lighter step
    /// in OKLCH; nothing becomes black and white.
    public static func usable(_ colors: [RGBAColor]) -> [RGBAColor] {
        var distinct: [RGBAColor] = []
        for color in colors.map(\.snapped) where !distinct.contains(color) { distinct.append(color) }
        if distinct.count >= 2 { return Array(distinct.prefix(FieldParameters.toneRange.upperBound)) }
        guard let only = distinct.first else { return [.black, .white] }
        return ramp(from: only)
    }

    /// A three-tone ramp around one color, the color in the middle; the
    /// steps go the way the color has room for.
    public static func ramp(from color: RGBAColor) -> [RGBAColor] {
        let lch = OKLCH(color)
        let down = OKLCH(l: max(0.08, lch.l - 0.28), c: lch.c, h: lch.h).color.snapped
        let up = OKLCH(l: min(0.97, lch.l + 0.28), c: lch.c * 0.8, h: lch.h).color.snapped
        var tones = [down, color.snapped, up]
        // Near an end of the lightness scale the outer step may land on the
        // color itself: keep whatever is distinct, and make sure two remain.
        var distinct: [RGBAColor] = []
        for tone in tones where !distinct.contains(tone) { distinct.append(tone) }
        if distinct.count < 2 { distinct = [OKLCH(l: lch.l < 0.5 ? 0.9 : 0.12, c: lch.c * 0.6, h: lch.h).color.snapped, color.snapped] }
        tones = distinct
        return tones
    }
}

extension OKLCH {
    /// Euclidean distance in OKLab: ~0.02 is barely visible, 0.1 clearly
    /// another color.
    public static func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let x = OKLCH(a), y = OKLCH(b)
        let ax = x.c * cos(x.h * .pi / 180), ay = x.c * sin(x.h * .pi / 180)
        let bx = y.c * cos(y.h * .pi / 180), by = y.c * sin(y.h * .pi / 180)
        let dl = x.l - y.l, da = ax - bx, db = ay - by
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
