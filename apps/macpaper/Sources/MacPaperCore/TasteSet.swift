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

    /// Chosen by eye from contact sheets of eight passing seeds per entry
    /// (RenderHarness `pick`), 2026-09-16.
    public static let entries: [Entry] = [
        Entry("Moiré atlas", "Mint Circuit", 6001),
        Entry("Moiré atlas", "Neon Night", 2),
        Entry("Moiré atlas", "Blueprint", 8003),
        Entry("Moiré atlas", "Magma", 9004),
        Entry("Moiré atlas", "Paper White", 8005),
        Entry("Moiré atlas", "Sea", 702),
        Entry("Moiré lattice", "Ultraviolet", 7006),
        Entry("Moiré lattice", "Sonar", 8),
        Entry("Contour relief", "Forest", 1009),
        Entry("Contour relief", "Oxide", 4010),
        Entry("Contour relief", "Dusk", 4011),
        Entry("Contour relief", "Clay", 1012),
        Entry("Pixel archipelago", "Sea", 13),
        Entry("Pixel archipelago", "Deep Sea", 3014),
        Entry("Pixel archipelago", "Lagoon", 10015),
        Entry("Pixel archipelago", "Moss", 7016),
        Entry("Resonance plate", "Charcoal", 8017),
        Entry("Resonance plate", "Cobalt Flash", 3018),
        Entry("Resonance plate", "Rose Heat", 3019),
        Entry("Woven circuit", "Board", 6020),
        Entry("Woven circuit", "Hazard", 7021),
        Entry("Woven circuit", "Navy Chalk", 10022),
        Entry("Woven circuit", "Signal", 9023),
        Entry("Memory sky", "Sunset Strip", 4024),
        Entry("Memory sky", "Twilight", 5025),
        Entry("Memory sky", "Ember", 26),
        Entry("Memory sky", "Peach Ice", 27),
        Entry("Dithered base", "Vaporwave", 1028),
        Entry("Dithered base", "Terminal Amber", 29),
        Entry("Dithered base", "Cyanotype", 30),
        Entry("Dithered base", "Newsprint", 31),
        Entry("Pattern grid", "Risograph", 2032),
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
