import Foundation
@testable import MacPaperCore
import Testing

// Fix round 1: retry exhaustion no longer applies an unvalidated candidate
// (P0-1), a one-color palette no longer bypasses the field's minimum tone
// count (P0-2), pins carry every promised value including a custom dark
// side (P1), the readability gate assesses local patches rather than the
// vacuous mean (P1), and lattice/weave are judged against their own family,
// not the atlas's (P1).

@Suite("Fix round 1 — retry exhaustion")
struct ExhaustionTests {
    static let renderer = WallpaperRenderer()
    static let context = RenderContext(size: PixelSize(width: 640, height: 400), menuBarStrip: 12)

    @Test("A pinned generator the gate always refuses (a bare gradient) exhausts to nothingBetter, never a document")
    func exhaustionOnBareGradient() {
        var template = Wallpaper(generator: .gradient(GradientParameters(kind: .linear, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1)
        template.pinned = [.generator]
        var g = SeededGenerator(seed: 5)
        let outcome = Shuffle.next(from: template, using: &g, renderer: Self.renderer, context: Self.context)
        #expect(outcome.document == nil)
        guard case .nothingBetter(let reason) = outcome else { Issue.record("expected nothingBetter, got \(outcome)"); return }
        #expect(reason.contains("bare"))
    }

    @Test("A pinned two-tone palette the gate always refuses for separation exhausts to nothingBetter, never a document")
    func exhaustionOnUnusablePalette() {
        var template = Wallpaper(generator: .field(FieldParameters(family: .interference, tones: [RGBAColor(hex: 0x202020), RGBAColor(hex: 0x242424)])), seed: 1)
        template.pinned = [.palette]
        var g = SeededGenerator(seed: 7)
        let outcome = Shuffle.next(from: template, using: &g, renderer: Self.renderer, context: Self.context)
        #expect(outcome.document == nil)
        guard case .nothingBetter(let reason) = outcome else { Issue.record("expected nothingBetter, got \(outcome)"); return }
        #expect(reason.contains("palette"))
    }

    @Test("The planner leaves a display with nothing better out of the plan; it can come back empty")
    func plannerOmitsNothingBetter() {
        var template = Wallpaper(generator: .gradient(GradientParameters(kind: .linear, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1)
        template.pinned = [.generator]
        var g = SeededGenerator(seed: 3)
        let display = DisplayInfo(id: 1, name: "A", pointSize: CGSize(width: 320, height: 200), scale: 2)
        let plan = ShufflePlanner.plan(displays: [display], current: [:], favorites: [], favoritesOnly: false, sameOnAllDisplays: true, template: template, using: &g)
        #expect(plan.isEmpty)
    }
}

@Suite("Fix round 1 — one-color palettes")
struct PaletteValidityTests {
    @Test("Palettes.usable turns empty, one, duplicate, two-distinct and over-six inputs into a usable palette")
    func usableFuzz() {
        #expect(Palettes.usable([]) == [.black, .white])
        let one = Palettes.usable([RGBAColor(hex: 0x336699)])
        #expect((2...6).contains(one.count) && Set(one).count == one.count, "a ramp, distinct")
        let duplicate = Palettes.usable([RGBAColor(hex: 0x336699), RGBAColor(hex: 0x336699)])
        #expect((2...6).contains(duplicate.count) && Set(duplicate).count == duplicate.count, "two identical colors are one color")
        let two = [RGBAColor(hex: 0x111111), RGBAColor(hex: 0xEEEEEE)]
        #expect(Palettes.usable(two) == two, "already usable: kept as is")
        let seven = (0..<7).map { RGBAColor(hex: UInt32(0x101010 * ($0 + 1))) }
        #expect(Set(seven).count == 7, "the fixture is actually seven distinct colors")
        #expect(Palettes.usable(seven).count == FieldParameters.toneRange.upperBound, "capped at six")
    }

    @Test("A one-color field renders every family at 64×40 without trapping")
    func oneColorFieldRenders() {
        let renderer = WallpaperRenderer()
        let size = PixelSize(width: 64, height: 40)
        for family in FieldFamily.allCases {
            let p = FieldParameters(family: family, tones: [RGBAColor(hex: 0x336699)])
            #expect(p.tones.count >= 2, Comment(rawValue: family.rawValue))
            let wallpaper = Wallpaper(generator: .field(p), seed: 1)
            let raster = renderer.render(wallpaper, size: size)
            #expect(raster.size == size, Comment(rawValue: family.rawValue))
        }
    }

    @Test("A pinned palette from a one-color solid template into a field candidate stays usable")
    func pinnedPaletteFromSolidIntoField() {
        let template = Wallpaper(generator: .solid(SolidParameters(color: RGBAColor(hex: 0x224466))), seed: 1, pinned: [.palette])
        let candidate = Wallpaper(generator: .field(FieldParameters(family: .relief, tones: Palettes.preset(named: "Sea")!.tones)), seed: 2)
        let out = Pins.apply([.palette], from: template, to: candidate)
        guard case .field(let p) = out.generator else { Issue.record("not a field"); return }
        #expect(p.tones.count >= 2)
        #expect(p.family == .relief, "the candidate's own field family is kept")
    }
}

@Suite("Fix round 1 — photo carry")
struct PhotoCarryTests {
    /// A 32×32 checkerboard, 2-pixel tiles: enough separation and local
    /// texture at pixelize block sizes (12…32) to actually clear the gate
    /// — a flat photo half (as `PixelizeTests`' red/blue source, or a
    /// bare background) does not: red/blue's own lightness separation is
    /// only ~0.18, and `.fill` at a big canvas mostly shows one flat half.
    static func checker(size: Int, tile: Int) -> Raster {
        var raster = Raster(size: PixelSize(width: size, height: size))
        for y in 0..<size {
            for x in 0..<size {
                let on = ((x / tile) + (y / tile)) % 2 == 0
                let v: UInt8 = on ? 255 : 0
                let i = (y * size + x) * 4
                raster.pixels[i] = v; raster.pixels[i + 1] = v; raster.pixels[i + 2] = v; raster.pixels[i + 3] = 255
            }
        }
        return raster
    }
    static let reference = ImageReference(fileName: "checker.png", contentHash: "checker")
    static let source = checker(size: 32, tile: 2)
    static let renderer = WallpaperRenderer(images: MemoryImages([reference: source]))

    // P0-1(d): a pinned generator carries the template's photo into a
    // freshly drawn pixelize candidate (the fix for the retry-exhaustion
    // finding: a pixelize draw with no source used to fail the gate every
    // time because the photo was silently dropped). Then the fix for the
    // gate itself (Curation.swift: a photo generator's separation now
    // reads the photo's own P95−P5 lightness off the structure, not
    // `wallpaper.colors`) lets a genuinely textured photo actually pass.
    @Test("A pinned generator carries the template's photo into a fresh pixelize draw, which then passes the gate")
    func pinnedPhotoShufflesAndPasses() throws {
        let context = RenderContext(size: PixelSize(width: 640, height: 400), menuBarStrip: 12)
        var template = Wallpaper(generator: .pixelize(PixelizeParameters(source: Self.reference, blockSize: 16, fit: .fill)), seed: 1)
        template.pinned = [.generator]
        var g = SeededGenerator(seed: 1)
        let outcome = Shuffle.next(from: template, using: &g, renderer: Self.renderer, context: context)
        let document = try #require(outcome.document, "a textured photo clears the gate within the attempt budget")
        #expect(document.generator.kind == .pixelize)
        #expect(document.generator.source == Self.reference, "the photo is never dropped")
        #expect(QualityGate.assess(document, renderer: Self.renderer, context: context).passes, "next only ever returns a passing candidate")
    }

    @Test("Pins.apply carries the template's photo, fit and focus into a freshly drawn pixelize candidate")
    func pinnedPhotoCarriesIntoPixelizeCandidate() {
        let source = ImageReference(fileName: "photo.png", contentHash: String(repeating: "a", count: 64))
        let template = Wallpaper(generator: .pixelize(PixelizeParameters(source: source, blockSize: 12, fit: .fill, focus: Point(x: 0.3, y: 0.7))), seed: 1, pinned: [.generator])
        let candidate = Wallpaper(generator: .pixelize(PixelizeParameters(source: nil, blockSize: 20)), seed: 2)
        let out = Pins.apply([.generator], from: template, to: candidate)
        guard case .pixelize(let p) = out.generator else { Issue.record("not pixelize"); return }
        #expect(p.source == source, "the photo is never dropped")
        #expect(p.fit == .fill && p.focus == Point(x: 0.3, y: 0.7), "its framing comes with it")
    }

    @Test("eligibleFamilies admits the pixelize family only once the template has a photo")
    func pixelizeFamilyNeedsAPhoto() {
        let noPhoto = Wallpaper(generator: .pixelize(PixelizeParameters(source: nil)), seed: 1)
        #expect(!Shuffle.eligibleFamilies(RecipeFamily.all, template: noPhoto, pinned: []).contains { $0.kind == .pixelize })
        let source = ImageReference(fileName: "photo.png", contentHash: String(repeating: "b", count: 64))
        let withPhoto = Wallpaper(generator: .pixelize(PixelizeParameters(source: source)), seed: 1)
        #expect(Shuffle.eligibleFamilies(RecipeFamily.all, template: withPhoto, pinned: []).contains { $0.kind == .pixelize })
    }
}

@Suite("Fix round 1 — pin gaps")
struct PinGapTests {
    @Test("A pinned .family narrows eligible families to the field's own; a pinned .generator does the same")
    func familyPinNarrows() {
        let islands = Wallpaper(generator: .field(FieldParameters(family: .islands, tones: Palettes.preset(named: "Sea")!.tones)), seed: 1)
        let byFamily = Shuffle.eligibleFamilies(RecipeFamily.all, template: islands, pinned: [.family])
        #expect(Set(byFamily.map(\.name)) == ["Pixel archipelago"])
        let byGenerator = Shuffle.eligibleFamilies(RecipeFamily.all, template: islands, pinned: [.generator])
        #expect(Set(byGenerator.map(\.name)) == ["Pixel archipelago"])
    }

    @Test("A pinned .generator on a mesh draft finds no field family: the draw keeps the template's own mesh")
    func generatorPinOnMeshLeavesNoFamily() {
        let mesh = Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: Palettes.preset(named: "Sea")!.tones)), seed: 1)
        #expect(Shuffle.eligibleFamilies(RecipeFamily.all, template: mesh, pinned: [.generator]).isEmpty, "no curated family makes a mesh")
    }

    @Test("A pinned .generator on a mesh draft draws from the template-generator path and can still pass the gate")
    func generatorPinOnMeshYieldsAMesh() throws {
        let palette = Palettes.preset(named: "Neon Night")!
        var template = Wallpaper(generator: .mesh(MeshParameters(columns: 4, rows: 3, colors: palette.tones, jitter: 1, softness: 0.1)), seed: 1)
        template.pinned = [.generator]
        var g = SeededGenerator(seed: 1)
        let context = RenderContext(size: PixelSize(width: 640, height: 400), menuBarStrip: 12)
        let outcome = Shuffle.next(from: template, using: &g, renderer: WallpaperRenderer(), context: context)
        let document = try #require(outcome.document, "a mesh with enough jitter and contrast clears the gate")
        #expect(document.generator.kind == .mesh)
    }

    @Test("Pins.apply carries a value pinned on a materialised custom dark side into the candidate's own darkGenerator")
    func darkSidePinsSurvive() throws {
        var lightP = FieldParameters(family: .interference, tones: Palettes.preset(named: "Sea")!.tones)
        lightP[.cellSize] = 8
        var darkP = lightP
        darkP[.cellSize] = 40 // edited by hand while editingSide == .dark
        let template = Wallpaper(generator: .field(lightP), seed: 1, darkGenerator: .field(darkP), pinned: [.cellSize])
        let candidate = Wallpaper(generator: .field(FieldParameters(family: .interference, tones: Palettes.preset(named: "Magma")!.tones)), seed: 2)
        let out = Pins.apply([.cellSize], from: template, to: candidate)
        guard case .field(let lightOut) = out.generator else { Issue.record("not a field"); return }
        #expect(lightOut.cellSize == 8, "the light side's pinned cell size")
        let dark = try #require(out.darkGenerator, "the custom dark side survives Pins.apply")
        guard case .field(let darkOut) = dark else { Issue.record("not a field"); return }
        #expect(darkOut.cellSize == 40, "the dark side's own pinned cell size, not the light side's darkened default")
    }

    @Test("The lattice and weave modes match the Moiré lattice family's quiet band, not the atlas's")
    func latticeMatchesItsOwnFamily() {
        var p = FieldParameters(family: .interference, tones: [.black, .white])
        p[.mode] = 0
        #expect(RecipeFamily.matching(Wallpaper(generator: .field(p), seed: 1))?.name == "Moiré atlas")
        p[.mode] = 1
        let lattice = RecipeFamily.matching(Wallpaper(generator: .field(p), seed: 1))
        #expect(lattice?.name == "Moiré lattice")
        #expect(lattice?.quiet == RecipeFamily.named("Moiré lattice")!.quiet)
        #expect(lattice?.quiet != RecipeFamily.named("Moiré atlas")!.quiet)
        p[.mode] = 2 // weave: the same family as the lattice
        #expect(RecipeFamily.matching(Wallpaper(generator: .field(p), seed: 1))?.name == "Moiré lattice")
    }
}

@Suite("Fix round 1 — readability")
struct ReadabilityFixTests {
    /// A 100×10 strip, mostly black with a bright sliver.
    static func stripRaster(brightShare: Double) -> Raster {
        var raster = Raster(width: 100, height: 10, fill: .black)
        let brightColumns = Int(Double(100) * brightShare)
        for x in (100 - brightColumns)..<100 {
            for y in 0..<10 {
                let i = (y * 100 + x) * 4
                raster.pixels[i] = 255; raster.pixels[i + 1] = 255; raster.pixels[i + 2] = 255
            }
        }
        return raster
    }

    @Test("A 95% black / 5% white strip fails readsEitherText even though the mean alone would pass")
    func localCollisionFails() {
        let readability = MenuBarReadability.assess(Self.stripRaster(brightShare: 0.05), stripHeight: 10, side: .dark)
        #expect(readability.contrastWithWhite >= 4.5, "the mean alone reads fine")
        #expect(!readability.readsEitherText, "a white patch collides with white text")
    }

    @Test("An even dark strip reads under the text it actually gets")
    func evenDarkPasses() {
        let raster = Raster(width: 100, height: 10, fill: RGBAColor(hex: 0x0A0A0A))
        let readability = MenuBarReadability.assess(raster, stripHeight: 10, side: .dark)
        #expect(readability.readsEitherText)
    }

    @Test("applyTopShade darkens a near-black strip further on the light side; it never flips a decisive strip")
    func topShadeReinforcesDark() {
        let renderer = WallpaperRenderer()
        let context = RenderContext(size: PixelSize(width: 64, height: 32), menuBarStrip: 4)
        let dim = RGBAColor(hex: 0x030303)
        let before = renderer.render(Wallpaper(generator: .solid(SolidParameters(color: dim)), seed: 1), side: .light, context: context)
        let after = renderer.render(Wallpaper(generator: .solid(SolidParameters(color: dim)), seed: 1, finish: Finish(topShade: 1)), side: .light, context: context)
        #expect(after.pixel(x: 0, y: 0).red < before.pixel(x: 0, y: 0).red, "darker still, not flipped toward white")
    }
}
