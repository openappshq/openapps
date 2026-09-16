import Foundation
@testable import MacPaperCore
import Testing

// Fix round 2: a same-on-all-displays draw is judged against every
// display's own render context, not just the first (P0 — the old
// single-context behavior let a document pass on the main display and
// fail the menu bar on a second one of a different size or notch); and
// Pins.apply carries a materialised dark side's own custom palette and
// photo, not the light side's derived ones (P1).

@Suite("Fix round 2 — same on all displays")
struct SameOnAllDisplaysTests {
    static let renderer = WallpaperRenderer()
    /// A 14" MacBook Pro with a notch, and a plain external display of a
    /// different aspect and pixel density: the two contexts `ShufflePlanner`
    /// builds (`contextFor` in Displays.swift) when "same on all displays" is on.
    static let main = DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 1512, height: 982), scale: 2, notchWidth: 200, isMain: true, topInset: 32)
    static let secondary = DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 1920, height: 1080), scale: 1, topInset: 24)
    static let displays = [main, secondary]

    @Test("A same-on-all-displays draw is either empty or the one document it picks passes the gate on every display's own context")
    func passesEveryContext() {
        for seed: UInt64 in 1...8 {
            var generator = SeededGenerator(seed: seed)
            let plan = ShufflePlanner.plan(displays: Self.displays, current: [:], favorites: [], favoritesOnly: false, sameOnAllDisplays: true, renderer: Self.renderer, using: &generator)
            guard !plan.isEmpty else { continue }
            let picked = Set(plan.values)
            #expect(picked.count == 1, "seed \(seed): one document for every display")
            guard let document = picked.first else { continue }
            for display in Self.displays {
                let verdict = QualityGate.assess(document, renderer: Self.renderer, context: display.renderContext)
                #expect(verdict.passes, "seed \(seed) on \(display.name): \(verdict.failures) \(verdict.metrics)")
            }
        }
    }

    @Test("Shuffle.next with both contexts never returns a document that fails the gate on either; the old single-context behavior (main only) is gone")
    func nextAcrossContexts() {
        var previous: Wallpaper?
        for seed: UInt64 in 1...8 {
            var generator = SeededGenerator(seed: seed)
            let outcome = Shuffle.next(from: previous, using: &generator, renderer: Self.renderer, contexts: [Self.main.renderContext, Self.secondary.renderContext])
            guard let document = outcome.document else { continue }
            for (name, context) in [("main", Self.main.renderContext), ("secondary", Self.secondary.renderContext)] {
                let verdict = QualityGate.assess(document, renderer: Self.renderer, context: context, previous: previous)
                #expect(verdict.passes, "seed \(seed) · \(name): \(verdict.failures) \(verdict.metrics)")
            }
            // A single-context assess (main alone) passing is not enough on
            // its own — this is the regression check: every document this
            // draw hands back must also pass on the *other* display.
            #expect(QualityGate.assess(document, renderer: Self.renderer, context: Self.secondary.renderContext, previous: previous).passes, "seed \(seed): fails on the secondary display, the exact review-2 regression")
            previous = document
        }
    }

    @Test("A pinned generator with no room to draw comes back as an empty plan — zero-apply, never a candidate that fails a display")
    func zeroApplyOnNoRoom() {
        var template = Wallpaper(generator: .gradient(GradientParameters(kind: .linear, stops: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)])), seed: 1)
        template.pinned = [.generator]
        var generator = SeededGenerator(seed: 3)
        let plan = ShufflePlanner.plan(displays: Self.displays, current: [:], favorites: [], favoritesOnly: false, sameOnAllDisplays: true, template: template, renderer: Self.renderer, using: &generator)
        #expect(plan.isEmpty, "a bare gradient never clears the gate on any display: zero-apply, not a refused candidate")
    }
}

@Suite("Fix round 2 — dark-side pins")
struct DarkSidePinCarryTests {
    @Test("The palette pin carries the dark side's own custom palette, not a fold of the light side's")
    func darkPaletteCarries() {
        let lightPalette = Palettes.preset(named: "Sea")!.tones
        let darkPalette = Palettes.preset(named: "Magma")!.tones
        var template = Wallpaper(generator: .field(FieldParameters(family: .interference, tones: lightPalette)), seed: 1)
        template.darkGenerator = .field(FieldParameters(family: .interference, tones: darkPalette))
        let candidate = Wallpaper(generator: .field(FieldParameters(family: .interference, tones: Palettes.preset(named: "Forest")!.tones)), seed: 2)
        let out = Pins.apply([.palette], from: template, to: candidate)
        #expect(out.generator.colors == Palettes.usable(lightPalette), "the light side takes the light side's own palette")
        guard case .field(let dark)? = out.darkGenerator else { Issue.record("the dark side's custom palette did not survive"); return }
        #expect(dark.tones == Palettes.usable(darkPalette), "the dark side keeps its own custom palette")
        #expect(dark.tones != out.generator.darkened().colors, "genuinely the dark side's own colors, not the derived fold of the light side's")
    }

    @Test("A photo pinned only on a materialised dark side carries into the candidate's own dark side, unconditionally — a photo is never dropped")
    func darkPhotoCarries() {
        let darkSource = ImageReference(fileName: "fedcba9876543210.png", contentHash: String(repeating: "b", count: 64))
        var template = Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: [.black, .white])), seed: 1)
        template.darkGenerator = .pixelize(PixelizeParameters(source: darkSource, blockSize: 20, fit: .fit, focus: Point(x: 0.3, y: 0.6)))
        let candidate = Wallpaper(generator: .pixelize(PixelizeParameters(source: nil, blockSize: 16)), seed: 2)
        // Nothing pinned: the light side (a mesh template, no photo) leaves
        // the candidate's own pixelize alone.
        let out = Pins.apply([], from: template, to: candidate)
        guard case .pixelize(let light) = out.generator else { Issue.record("not pixelize"); return }
        #expect(light.source == nil)
        guard case .pixelize(let dark)? = out.darkGenerator else { Issue.record("the dark side's photo did not survive"); return }
        #expect(dark.source == darkSource && dark.fit == .fit && dark.focus == Point(x: 0.3, y: 0.6), "the photo, and its framing, carried from the dark side alone")
    }
}
