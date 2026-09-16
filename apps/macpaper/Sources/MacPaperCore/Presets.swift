import Foundation

/// A curated palette: a name and three to five colors that read as one
/// wallpaper, defined as OKLCH stops so every color sits in the sRGB gamut
/// at a lightness the panel can predict (`OKLCH.color` clips chroma, never
/// lightness or hue).
public struct PresetPalette: Hashable, Identifiable, Sendable {
    public let name: String
    public let stops: [OKLCH]

    public init(name: String, stops: [OKLCH]) {
        self.name = name
        self.stops = stops
    }

    public var id: String { name }

    public var colors: [RGBAColor] { stops.map(\.color) }
}

/// The preset palettes the panel's Palette section shows as a grid: one
/// ramp per family, on the OKLCH lightness steps the shared ramps use
/// (design/tokens.json steps 950 → 50 sit near l 0.22, 0.42, 0.66, 0.88).
/// Dark-to-light within a family, so the first color is the ground and
/// the last the highlight, the way every generator reads a palette.
public enum PresetPalettes {
    /// The lightness steps of a four-stop ramp.
    static let ramp: [Double] = [0.22, 0.42, 0.66, 0.88]

    /// One hue, four steps; `chroma` scaled down at the ends where the
    /// gamut narrows.
    static func mono(_ name: String, hue: Double, chroma: Double) -> PresetPalette {
        PresetPalette(name: name, stops: [
            OKLCH(l: ramp[0], c: chroma * 0.55, h: hue),
            OKLCH(l: ramp[1], c: chroma, h: hue),
            OKLCH(l: ramp[2], c: chroma, h: hue),
            OKLCH(l: ramp[3], c: chroma * 0.45, h: hue),
        ])
    }

    /// Two hues, dark on the first and light on the second.
    static func duo(_ name: String, from: Double, to: Double, chroma: Double) -> PresetPalette {
        PresetPalette(name: name, stops: [
            OKLCH(l: 0.26, c: chroma * 0.7, h: from),
            OKLCH(l: 0.5, c: chroma, h: from),
            OKLCH(l: 0.66, c: chroma, h: to),
            OKLCH(l: 0.88, c: chroma * 0.5, h: to),
        ])
    }

    /// Three hues across the wheel at one lightness band, with a dark
    /// ground: the loud ones.
    static func trio(_ name: String, hues: [Double], chroma: Double, ground: Double = 0.2) -> PresetPalette {
        PresetPalette(name: name, stops: [OKLCH(l: ground, c: chroma * 0.4, h: hues[0])] + hues.map { OKLCH(l: 0.7, c: chroma, h: $0) })
    }

    /// Near-greys with a hint of one hue.
    static func tinted(_ name: String, hue: Double) -> PresetPalette {
        PresetPalette(name: name, stops: [
            OKLCH(l: 0.18, c: 0.012, h: hue),
            OKLCH(l: 0.36, c: 0.02, h: hue),
            OKLCH(l: 0.62, c: 0.025, h: hue),
            OKLCH(l: 0.9, c: 0.012, h: hue),
        ])
    }

    /// A pale field: two light tones and one deep accent.
    static func pale(_ name: String, hue: Double, accent: Double, chroma: Double) -> PresetPalette {
        PresetPalette(name: name, stops: [
            OKLCH(l: 0.36, c: chroma, h: accent),
            OKLCH(l: 0.82, c: chroma * 0.5, h: hue),
            OKLCH(l: 0.9, c: chroma * 0.35, h: hue),
            OKLCH(l: 0.96, c: chroma * 0.15, h: hue),
        ])
    }

    /// A dark field: three deep tones and one bright accent.
    static func deep(_ name: String, hue: Double, accent: Double, chroma: Double) -> PresetPalette {
        PresetPalette(name: name, stops: [
            OKLCH(l: 0.14, c: chroma * 0.3, h: hue),
            OKLCH(l: 0.22, c: chroma * 0.45, h: hue),
            OKLCH(l: 0.32, c: chroma * 0.6, h: hue),
            OKLCH(l: 0.74, c: chroma, h: accent),
        ])
    }

    public static let all: [PresetPalette] = [
        // The brand ramp first.
        mono("Tangerine", hue: 45, chroma: 0.17),
        mono("Ember", hue: 30, chroma: 0.16),
        mono("Coral", hue: 22, chroma: 0.15),
        mono("Rose", hue: 5, chroma: 0.14),
        mono("Berry", hue: 350, chroma: 0.15),
        mono("Plum", hue: 320, chroma: 0.13),
        mono("Orchid", hue: 335, chroma: 0.12),
        mono("Lilac", hue: 300, chroma: 0.11),
        mono("Violet", hue: 290, chroma: 0.15),
        mono("Cobalt", hue: 265, chroma: 0.17),
        mono("Denim", hue: 255, chroma: 0.11),
        mono("Sea", hue: 240, chroma: 0.13),
        mono("Lagoon", hue: 215, chroma: 0.12),
        mono("Teal", hue: 195, chroma: 0.11),
        mono("Mint", hue: 165, chroma: 0.11),
        mono("Forest", hue: 150, chroma: 0.11),
        mono("Moss", hue: 130, chroma: 0.1),
        mono("Olive", hue: 110, chroma: 0.09),
        mono("Citrus", hue: 95, chroma: 0.15),
        mono("Honey", hue: 80, chroma: 0.15),
        mono("Saffron", hue: 65, chroma: 0.17),
        mono("Rust", hue: 40, chroma: 0.12),
        duo("Sunset", from: 30, to: 340, chroma: 0.15),
        duo("Dawn", from: 300, to: 60, chroma: 0.12),
        duo("Dusk", from: 270, to: 20, chroma: 0.12),
        duo("Aurora", from: 170, to: 300, chroma: 0.12),
        duo("Reef", from: 220, to: 160, chroma: 0.12),
        duo("Meadow", from: 140, to: 95, chroma: 0.11),
        duo("Peach", from: 35, to: 70, chroma: 0.13),
        duo("Sorbet", from: 350, to: 45, chroma: 0.13),
        duo("Glacier", from: 250, to: 200, chroma: 0.09),
        duo("Wine", from: 355, to: 320, chroma: 0.12),
        duo("Ocean", from: 260, to: 220, chroma: 0.13),
        duo("Canyon", from: 30, to: 50, chroma: 0.1),
        trio("Neon", hues: [330, 200, 100], chroma: 0.19),
        trio("Carnival", hues: [20, 290, 160], chroma: 0.17),
        trio("Prism", hues: [260, 40, 150], chroma: 0.16),
        trio("Tropic", hues: [180, 60, 340], chroma: 0.15),
        tinted("Charcoal", hue: 260),
        tinted("Slate", hue: 240),
        tinted("Graphite", hue: 60),
        tinted("Smoke", hue: 30),
        tinted("Stone", hue: 90),
        pale("Paper", hue: 70, accent: 30, chroma: 0.12),
        pale("Bone", hue: 80, accent: 250, chroma: 0.1),
        pale("Frost", hue: 230, accent: 260, chroma: 0.1),
        pale("Blush", hue: 15, accent: 350, chroma: 0.12),
        pale("Sage", hue: 140, accent: 150, chroma: 0.08),
        deep("Midnight", hue: 260, accent: 220, chroma: 0.16),
        deep("Noir", hue: 300, accent: 30, chroma: 0.16),
        deep("Pine", hue: 160, accent: 120, chroma: 0.14),
        deep("Cocoa", hue: 40, accent: 60, chroma: 0.14),
        deep("Ink", hue: 240, accent: 340, chroma: 0.16),
        deep("Obsidian", hue: 280, accent: 190, chroma: 0.15),
    ]

    public static func named(_ name: String) -> PresetPalette? {
        all.first { $0.name == name }
    }

    /// The preset whose colors a document uses, if any: the same colors in
    /// the same order, or the same set (a generator that took a subset of
    /// a palette still counts as that palette when every color it has is
    /// from it and it has at least two).
    public static func matching(_ colors: [RGBAColor]) -> PresetPalette? {
        guard colors.count >= 2 else { return nil }
        let set = Set(colors.map(\.hexString))
        return all.first { $0.colors.map(\.hexString) == colors.map(\.hexString) }
            ?? all.first { set.isSubset(of: Set($0.colors.map(\.hexString))) }
    }

    /// "Sunset" or "Custom": how a recipe is titled.
    public static func name(for colors: [RGBAColor]) -> String {
        matching(colors)?.name ?? "Custom"
    }
}

/// A built-in recipe: a named document the Library offers to start from.
public struct StarterRecipe: Hashable, Identifiable, Sendable {
    public let name: String
    public let wallpaper: Wallpaper

    public init(name: String, wallpaper: Wallpaper) {
        self.name = name
        self.wallpaper = wallpaper
    }

    public var id: String { name }
}

/// The starters the Library lists under the saved recipes: complete
/// documents (a generator on a preset palette, with its finishes set, a
/// fixed seed) that render the same on every Mac. Never a gradient or a
/// flat color on its own, and never one that needs a photo.
public enum StarterRecipes {
    static func mesh(_ name: String, palette: String, seed: UInt64, columns: Int = 3, rows: Int = 3, jitter: Double = 0.55, softness: Double = 0.6, grain: Double = 0.08, composition: Composition = .none, pair: PairMode = .lightDark) -> StarterRecipe {
        let colors = PresetPalettes.named(palette)?.colors ?? PresetPalettes.all[0].colors
        return StarterRecipe(name: name, wallpaper: Wallpaper(
            generator: .mesh(MeshParameters(columns: columns, rows: rows, colors: colors, jitter: jitter, softness: softness)),
            seed: seed, grain: grain, pair: pair, composition: composition
        ))
    }

    static func pattern(_ name: String, palette: String, kind: PatternKind, seed: UInt64, scale: Double, angle: Double = 0, grain: Double = 0.06, topShade: Double = 0, composition: Composition = .none) -> StarterRecipe {
        let colors = PresetPalettes.named(palette)?.colors ?? PresetPalettes.all[0].colors
        return StarterRecipe(name: name, wallpaper: Wallpaper(
            generator: .pattern(PatternParameters(kind: kind, foreground: colors[colors.count - 1], background: colors[0], scale: scale, angle: angle)),
            seed: seed, grain: grain, finish: Finish(topShade: topShade), pair: .lightDark, composition: composition
        ))
    }

    public static let all: [StarterRecipe] = [
        mesh("Tangerine field", palette: "Tangerine", seed: 20_260_916, composition: .emerge),
        mesh("Midnight drift", palette: "Midnight", seed: 41, columns: 4, rows: 3, jitter: 0.7, softness: 0.7, grain: 0.1),
        mesh("Aurora", palette: "Aurora", seed: 7, columns: 3, rows: 2, jitter: 0.6, softness: 0.75, grain: 0.06),
        mesh("Sorbet", palette: "Sorbet", seed: 19, columns: 2, rows: 2, jitter: 0.4, softness: 0.8, grain: 0.05),
        pattern("Graphite dots", palette: "Graphite", kind: .dots, seed: 3, scale: 56, grain: 0.08, composition: .contours),
        pattern("Ink lines", palette: "Ink", kind: .lines, seed: 5, scale: 40, angle: 45, grain: 0.05),
        pattern("Slate checks", palette: "Slate", kind: .checks, seed: 8, scale: 96, angle: 45, grain: 0.04),
        pattern("Cocoa noise", palette: "Cocoa", kind: .noise, seed: 12, scale: 64, grain: 0.12, topShade: 0.3),
    ]
}
