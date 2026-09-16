import Foundation

/// The recipes macPaper ships with: the default library on a fresh
/// install, and the seeds the shuffle families are calibrated on. Each is
/// a family drawn with a preset palette from a chosen seed, looked at and
/// kept; the gate must pass every one (a test says so).
public enum TasteSet {
    /// A family, a palette and the seed the family was drawn with.
    public struct Entry: Sendable {
        public let family: String
        public let palette: String
        public let seed: UInt64
        public let name: String?

        public init(_ family: String, _ palette: String, _ seed: UInt64, name: String? = nil) {
            self.family = family
            self.palette = palette
            self.seed = seed
            self.name = name
        }

        public var wallpaper: Wallpaper {
            guard let family = RecipeFamily.named(family), let palette = Palettes.preset(named: palette) else { return Wallpaper.fallback }
            var generator = SeededGenerator(seed: seed)
            var wallpaper = family.draw(palette, &generator)
            wallpaper.seed = seed
            return wallpaper
        }

        /// Stable ids and dates, so a fresh install's library is the same
        /// on every Mac.
        public var recipe: Recipe {
            let document = wallpaper
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", seed & 0xFFFF_FFFF_FFFF)) ?? UUID()
            return Recipe(id: id, name: name ?? "\(palette) · \(Recipe.generatorTitle(for: document))", wallpaper: document, addedAt: Date(timeIntervalSince1970: 1_789_000_000))
        }
    }

    public static let entries: [Entry] = [
        Entry("Moiré atlas", "Mint Circuit", 1),
        Entry("Moiré atlas", "Neon Night", 2),
        Entry("Moiré atlas", "Blueprint", 3),
        Entry("Moiré atlas", "Magma", 4),
        Entry("Moiré atlas", "Paper White", 5),
        Entry("Moiré lattice", "Ultraviolet", 6),
        Entry("Moiré lattice", "Rust", 7),
        Entry("Moiré lattice", "Sonar", 8),
        Entry("Contour relief", "Forest", 9),
        Entry("Contour relief", "Oxide", 10),
        Entry("Contour relief", "Dusk", 11),
        Entry("Contour relief", "Clay", 12),
        Entry("Pixel archipelago", "Sea", 13),
        Entry("Pixel archipelago", "Deep Sea", 14),
        Entry("Pixel archipelago", "Lagoon", 15),
        Entry("Pixel archipelago", "Moss", 16),
        Entry("Resonance plate", "Charcoal", 17),
        Entry("Resonance plate", "Cobalt Flash", 18),
        Entry("Resonance plate", "Rose Heat", 19),
        Entry("Woven circuit", "Board", 20),
        Entry("Woven circuit", "Hazard", 21),
        Entry("Woven circuit", "Navy Chalk", 22),
        Entry("Woven circuit", "Signal", 23),
        Entry("Memory sky", "Sunset Strip", 24),
        Entry("Memory sky", "Twilight", 25),
        Entry("Memory sky", "Ember", 26),
        Entry("Memory sky", "Peach Ice", 27),
        Entry("Dithered base", "Vaporwave", 28),
        Entry("Dithered base", "Terminal Amber", 29),
        Entry("Dithered base", "Cyanotype", 30),
        Entry("Dithered base", "Newsprint", 31),
        Entry("Pattern grid", "Risograph", 32),
        Entry("Pattern grid", "Grid Blue", 33),
        Entry("Pattern grid", "Copper", 34),
    ]

    public static let recipes: [Recipe] = entries.map(\.recipe)
}

extension Wallpaper {
    /// A document that needs nothing looked up: what a taste-set entry
    /// whose family or palette went missing falls back to.
    static let fallback = Wallpaper(generator: .field(FieldParameters(family: .interference, tones: [RGBAColor(hex: 0x1B2B2A), RGBAColor(hex: 0x4FA38B), RGBAColor(hex: 0xC8F2E3)])), seed: 1, grain: 0.04, finish: Finish(vignette: 0.2), base: .solid(RGBAColor(hex: 0x1B2B2A)))
}
