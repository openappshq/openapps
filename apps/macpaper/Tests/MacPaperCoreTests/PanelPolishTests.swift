import Foundation
@testable import MacPaperCore
import Testing

@Suite("Panel layout")
struct PanelLayoutTests {
    @Test("A segmented control is as wide as its widest label in every segment, so nothing wraps")
    func segmentedWidth() {
        // Four labels, the widest 68 points: four segments of 68 + 20, three gaps, the inset.
        let width = PanelLayout.segmentedWidth(labelWidths: [30, 44, 52.4, 68])
        let expected: CGFloat = 4 * 88 + 6 + 4
        #expect(width == expected)
        #expect(PanelLayout.segmentedWidth(labelWidths: []) == 0)
        let single: CGFloat = 34
        #expect(PanelLayout.segmentedWidth(labelWidths: [10]) == single)
    }

    @Test("The column is the setting's width unless a control needs more")
    func columnWidth() {
        #expect(PanelLayout.columnWidth(setting: .regular, controlWidths: [200, 300]) == 440)
        let needed = PanelLayout.columnWidth(setting: .compact, controlWidths: [330])
        #expect(needed == 330 + PanelLayout.railWidth + 2 * PanelLayout.paneInset)
        #expect(PanelLayout.columnWidth(setting: .wide, controlWidths: []) == 560)
        #expect(PanelLayout.paneWidth(columnWidth: 440) == CGFloat(440 - 56 - 40))
    }

    @Test("The column takes most of the screen under the top inset, capped")
    func columnHeight() {
        #expect(PanelLayout.columnHeight(screenHeight: 982, topInset: 37) == PanelLayout.maximumHeight, "921 would fit; the cap wins")
        #expect(PanelLayout.columnHeight(screenHeight: 900, topInset: 37) == 900 - 37 - PanelLayout.bottomMargin)
        #expect(PanelLayout.columnHeight(screenHeight: 1440, topInset: 30) == PanelLayout.maximumHeight)
        #expect(PanelLayout.columnHeight(screenHeight: 20, topInset: 37) == 0)
    }
}

@Suite("Panel anchor")
struct PanelAnchorTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let notch = CGRect(x: 630, y: 945, width: 252, height: 37)

    @Test("The top inset is the notch on a notched display and the menu bar plus the popover's gap elsewhere")
    func topInset() {
        #expect(NotchGeometry.topInset(for: .notch(Self.notch, menuBarHeight: 37)) == 37)
        #expect(NotchGeometry.topInset(for: .notch(Self.notch, menuBarHeight: 40)) == 40, "a menu bar taller than the notch wins")
        #expect(NotchGeometry.topInset(for: .statusItem(CGRect(x: 1300, y: 958, width: 28, height: 24), menuBarHeight: 24)) == 24 + PanelLayout.popoverGap)
        #expect(NotchGeometry.topInset(for: .topCenter(menuBarHeight: 25)) == 25 + PanelLayout.popoverGap)
    }

    @Test("On a notch the column is centered on it and squared against it; under the item its trailing edges meet")
    func frames() {
        let onNotch = NotchGeometry.panelFrame(screenFrame: Self.screen, anchor: .notch(Self.notch, menuBarHeight: 37), width: 440, contentHeight: 900)
        #expect(onNotch == CGRect(x: 756 - 220, y: 945 - 900, width: 440, height: 900))
        let item = CGRect(x: 1380, y: 958, width: 28, height: 24)
        let underItem = NotchGeometry.panelFrame(screenFrame: Self.screen, anchor: .statusItem(item, menuBarHeight: 24), width: 440, contentHeight: 900)
        #expect(underItem.maxX == item.maxX)
        #expect(underItem.maxY == 982 - 24 - PanelLayout.popoverGap)
        // An item near the left edge: the column stays on screen.
        let leftItem = CGRect(x: 100, y: 958, width: 28, height: 24)
        #expect(NotchGeometry.panelFrame(screenFrame: Self.screen, anchor: .statusItem(leftItem, menuBarHeight: 24), width: 440, contentHeight: 900).minX == 0)
        // A screen with its origin elsewhere.
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let centered = NotchGeometry.panelFrame(screenFrame: external, anchor: .topCenter(menuBarHeight: 24), width: 560, contentHeight: 900)
        #expect(centered.midX == external.midX && centered.maxY == 1440 - 24 - PanelLayout.popoverGap)
    }

    @Test("The menu-bar shade sits over the column on a notch only")
    func shade() {
        let anchor = PanelAnchor.notch(Self.notch, menuBarHeight: 37)
        let frame = NotchGeometry.panelFrame(screenFrame: Self.screen, anchor: anchor, width: 440, contentHeight: 900)
        #expect(NotchGeometry.menuBarShadeFrame(screenFrame: Self.screen, anchor: anchor, panelFrame: frame) == CGRect(x: frame.minX, y: 945, width: 440, height: 37))
        let item = PanelAnchor.statusItem(CGRect(x: 1380, y: 958, width: 28, height: 24), menuBarHeight: 24)
        #expect(NotchGeometry.menuBarShadeFrame(screenFrame: Self.screen, anchor: item, panelFrame: frame) == nil)
        #expect(NotchGeometry.menuBarShadeFrame(screenFrame: Self.screen, anchor: .topCenter(menuBarHeight: 24), panelFrame: frame) == nil)
    }
}

@Suite("Panel theme")
struct PanelThemeTests {
    /// The four desktops the harness draws the column over.
    static let backdrops: [RGBAColor] = [RGBAColor(hex: 0xFF7A2F), RGBAColor(hex: 0x858585), RGBAColor(hex: 0x0A0A0A), RGBAColor(hex: 0xF6F6F6)]

    @Test("Every text and control pair on the column reaches AA, over any wallpaper")
    func contrast() {
        #expect(PanelTheme.groundAlpha == 1, "the ground is opaque")
        for backdrop in Self.backdrops {
            let ground = PanelTheme.ground(over: backdrop)
            #expect(ground.hexString == PanelTheme.ground.hexString, "\(backdrop.hexString) shows through")
            for pair in PanelTheme.pairs {
                let background = pair.background == PanelTheme.ground ? ground : pair.background
                let ratio = Contrast.ratio(pair.foreground, background)
                #expect(ratio >= pair.minimum, "\(pair.name): \(ratio) over \(backdrop.hexString)")
            }
        }
    }

    @Test("The contrast formula matches the token file's checks")
    func formula() {
        // design/tokens.json: tangerine/300 with neutral/950 text is 10.66.
        #expect(abs(Contrast.ratio(RGBAColor(hex: 0xFFB48A), RGBAColor(hex: 0x141414)) - 10.66) < 0.02)
        #expect(abs(Contrast.ratio(.white, .black) - 21) < 0.001)
        #expect(Contrast.composite(RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5), over: .white).red == 0.5)
    }
}

@Suite("Preset palettes")
struct PresetPaletteTests {
    // `Palettes.presets` itself (count, uniqueness, gamut, distinctness) is
    // covered by GeneratorDepthTests.PaletteTests.rule(); this keeps only
    // what that suite does not: subset matching, and the panel's own order.

    @Test("A document's colors name their preset, a subset included; anything else is Custom")
    func matching() {
        let sea = Palettes.preset(named: "Sea")!
        #expect(Palettes.preset(matching: sea.tones)?.name == "Sea")
        #expect(Palettes.preset(matching: Array(sea.tones.prefix(2)))?.name == "Sea", "a two-color generator on the palette")
        #expect(Palettes.preset(matching: [sea.tones[0]]) == nil, "one color is no palette")
        #expect(Palettes.name(for: [RGBAColor(hex: 0x123456), RGBAColor(hex: 0x654321)]) == "Custom")
        #expect(Palettes.preset(named: "Nope") == nil)
    }

    /// The documents a preset lands in: the looks the panel and Shuffle make.
    static let contexts: [(String, @Sendable (Palette) -> Wallpaper)] = [
        ("mesh emerge", { Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: $0.tones, jitter: 0.6, softness: 0.5)), seed: 42, grain: 0.08, pair: .lightDark, composition: .emerge) }),
        ("mesh busy", { Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: $0.tones, jitter: 0.9, softness: 0.3)), seed: 7) }),
        ("dots", { Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: $0.tones.last!, background: $0.tones[0], scale: 48)), seed: 3, grain: 0.1) }),
        ("lines", { Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: $0.tones.last!, background: $0.tones[1], scale: 40, angle: 45)), seed: 5) }),
    ]

    // Renders every preset through four contexts, lifted and a tenth lower:
    // minutes in a debug build, so heavy (RELEASES.md, "Pipeline").
    @Test("Every preset, in every context, reads on both sides once lifted; the lift is the smallest shade that does", .heavy, .tags(.heavy))
    func presetsRead() {
        let renderer = WallpaperRenderer()
        let context = RenderContext(size: PixelSize(width: 640, height: 400), menuBarStrip: 12)
        for preset in Palettes.presets {
            for (name, make) in Self.contexts {
                let lifted = make(preset).liftingMenuBar(context: context, renderer: renderer)
                for side in Side.allCases {
                    #expect(lifted.menuBarReads(side: side, context: context, renderer: renderer), "\(preset.name) · \(name) · \(side)")
                }
                if lifted.finish.topShade > 0 {
                    var lower = lifted
                    lower.finish.topShade = max(0, lifted.finish.topShade - 0.1)
                    #expect(!Side.allCases.allSatisfy { lower.menuBarReads(side: $0, context: context, renderer: renderer) }, "\(preset.name) · \(name): a tenth less would not read")
                }
            }
        }
    }

    @Test("The panel lists the pixel-field families, then dither, mesh, pixelize and pattern; flat and gradient are the base layer")
    func order() {
        #expect(GeneratorKind.panelOrder == [.field, .dither, .mesh, .pixelize, .pattern])
        #expect(GeneratorKind.baseLayers == [.solid, .gradient])
        #expect(!GeneratorKind.shuffleable.contains { $0.isBaseLayer })
        #expect(GeneratorChoice.panelOrder.count == FieldFamily.allCases.count + 4, "the six families, then dither, mesh, pixelize, pattern")
        #expect(!GeneratorChoice.panelOrder.contains { $0.kind == .gradient || $0.kind == .solid })
        for (index, family) in FieldFamily.allCases.enumerated() {
            #expect(GeneratorChoice.panelOrder[index] == .family(family), "the families lead, in FieldFamily's own order")
        }
        #expect(GeneratorChoice.panelOrder.suffix(4).map(\.kind) == [.dither, .mesh, .pixelize, .pattern])
    }

    // Forty random documents through Shuffle's quality gate: minutes in a
    // debug build, so heavy (RELEASES.md, "Pipeline"); the rule itself is
    // `GeneratorKind.shuffleable` above.
    @Test("Shuffle never makes a base layer", .heavy, .tags(.heavy))
    func shuffleNeverMakesABaseLayer() {
        var generator = SeededGenerator(seed: 9)
        for _ in 0..<40 { #expect(!Wallpaper.random(using: &generator).generator.kind.isBaseLayer) }
    }
}

@Suite("Pins")
struct PinTests {
    // Per-generator knob carrying (pattern, mesh, dither, gradient) is
    // covered thoroughly by GeneratorDepthTests.PinsTests; this keeps what
    // that suite does not: document-wide pins, the palette pin, framing
    // (source carry), the dark side, and the JSON/title contract.
    static let mesh = Wallpaper(generator: .mesh(MeshParameters(columns: 4, rows: 2, colors: Palettes.preset(named: "Sea")!.tones, jitter: 0.9, softness: 0.2)), seed: 7, grain: 0.3, finish: Finish(topShade: 0.5), pair: .lightDark, composition: .emerge)
    static let pattern = Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: .white, background: .black, scale: 120, angle: 45)), seed: 99)

    @Test("Nothing pinned: the candidate is untouched")
    func none() {
        #expect(Pins.apply([], from: Self.mesh, to: Self.pattern) == Self.pattern)
    }

    @Test("Document-wide pins copy their value and leave the generator alone")
    func documentWide() {
        let pins: Set<ParameterKey> = [.seed, .grain, .topShade, .composition, .pair]
        let out = Pins.apply(pins, from: Self.mesh, to: Self.pattern)
        #expect(out.generator == Self.pattern.generator)
        #expect(out.seed == 7 && out.grain == 0.3 && out.finish.topShade == 0.5 && out.composition == .emerge && out.pair == .lightDark)
    }

    @Test("The palette pin recolors the candidate in the current colors")
    func palette() {
        let out = Pins.apply([.palette], from: Self.mesh, to: Self.pattern)
        guard case .pattern(let p) = out.generator else { Issue.record("not a pattern"); return }
        let sea = Palettes.preset(named: "Sea")!.tones
        #expect(p.background == sea[0] && p.foreground == sea[sea.count - 1])
        #expect(p.kind == .lines && p.scale == 120, "only the colors changed")
    }

    @Test("Framing pins carry the template's photo, fit and focus into a matching-kind candidate")
    func framing() {
        let reference = ImageReference(fileName: "0123456789abcdef.png", contentHash: String(repeating: "a", count: 64))
        let current = Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 40, fit: .fit, focus: Point(x: 0.2, y: 0.8))), seed: 3)
        let candidate = Wallpaper(generator: .pixelize(PixelizeParameters(source: nil, blockSize: 16)), seed: 4)
        let out = Pins.apply([.framing], from: current, to: candidate)
        guard case .pixelize(let p) = out.generator else { Issue.record("not pixelize"); return }
        // The photo is never dropped, pin or not; the framing pin carries fit and focus.
        #expect(p.source == reference && p.fit == .fit && p.focus == Point(x: 0.2, y: 0.8))
        #expect(p.blockSize == 16, "unpinned: the candidate's own")
    }

    @Test("Pins carry per side: a value pinned on an edited dark side survives as the dark side's, the light side keeps its own")
    func bothSides() {
        var current = Self.mesh
        // The light side at jitter 0.1, the dark side edited by hand to 0.9.
        current.generator = .mesh(MeshParameters(columns: 3, rows: 3, colors: [.black, .white], jitter: 0.1, softness: 0.5))
        current.darkGenerator = .mesh(MeshParameters(columns: 3, rows: 3, colors: [RGBAColor(hex: 0x102030), RGBAColor(hex: 0x405060)], jitter: 0.9, softness: 0.4))
        let candidate = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.preset(named: "Sea")!.tones, jitter: 0.5, softness: 0.5)), seed: 3)
        let out = Pins.apply([.jitter], from: current, to: candidate)
        guard case .mesh(let light) = out.generator, case .mesh(let dark)? = out.darkGenerator else { Issue.record("sides missing"); return }
        #expect(light.jitter == 0.1, "the light side keeps the light side's jitter")
        #expect(dark.jitter == 0.9, "the dark side keeps the dark side's jitter")
        #expect(dark.colors == candidate.generator.darkened().colors, "the dark side is the candidate's derived dark side otherwise")
        #expect(out.generator(for: .dark) == out.darkGenerator)
        // The palette pinned: each side's own colors, the dark side's own custom palette included.
        let palette = Pins.apply([.palette], from: current, to: candidate)
        #expect(palette.generator.colors == [.black, .white])
        #expect(palette.darkGenerator?.colors == [RGBAColor(hex: 0x102030), RGBAColor(hex: 0x405060)])
        // No custom dark side: the candidate's stays derived from the carried light side.
        let derived = Pins.apply([.jitter], from: Self.mesh, to: candidate)
        #expect(derived.darkGenerator == nil)
        if case .mesh(let p) = derived.generator(for: .dark) { #expect(p.jitter == 0.9) } else { Issue.record("not a mesh") }
    }

    @Test("Pins round-trip as JSON and every parameter key has a title")
    func codable() throws {
        let pins: Set<ParameterKey> = [.seed, .cell]
        let data = try JSONEncoder().encode(pins)
        #expect(try JSONDecoder().decode(Set<ParameterKey>.self, from: data) == pins)
        for key in ParameterKey.allCases {
            #expect(!key.title.isEmpty, Comment(rawValue: key.rawValue))
        }
    }
}

@Suite("Library and history")
struct LibraryStoreTests {
    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-library-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A favorite carries a name, is named from its palette and generator without one, and old files decode")
    func names() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoritesStore(fileURL: directory.appendingPathComponent("favorites.json"))
        let sea = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: Palettes.preset(named: "Sea")!.tones)), seed: 1)
        let saved = try store.add(sea)
        #expect(saved.name == "Sea · Mesh")
        let renamed = try store.add(sea, named: "Deep end")
        #expect(renamed.id == saved.id && renamed.name == "Deep end")
        #expect(try store.add(sea, named: "  ").name == "Deep end", "blank keeps the name")
        try store.rename(renamed.id, to: "")
        #expect(store.all[0].name == "Sea · Mesh")
        // A file from before names.
        let old = """
        {"version":1,"favorites":[{"id":"\(UUID().uuidString)","addedAt":"2026-09-16T00:00:00Z","wallpaper":\(String(decoding: try Wallpaper.starter.jsonData(), as: UTF8.self))}]}
        """
        let oldURL = directory.appendingPathComponent("old.json")
        try Data(old.utf8).write(to: oldURL)
        let reloaded = FavoritesStore(fileURL: oldURL)
        #expect(reloaded.all.count == 1 && reloaded.all[0].name == Recipe.defaultName(for: .starter))
    }

    @Test("History keeps one entry per look, newest first, bounded, and survives a reload")
    func history() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: url, limit: 3)
        let a = Wallpaper.starter
        try store.record(a)
        var tweaked = a
        tweaked.grain = 0.5
        try store.record(tweaked)
        #expect(store.all.count == 1 && store.all[0].wallpaper == tweaked, "a slider moved: the same look, replaced")
        try store.record(a.reseeded(2))
        #expect(store.all.count == 2 && store.all[0].wallpaper.seed == 2, "a new seed: a new entry, first")
        try store.record(Wallpaper.trueBlack)
        try store.record(a.reseeded(5))
        #expect(store.all.count == 3, "bounded")
        #expect(!store.all.contains { $0.wallpaper == tweaked }, "the oldest went")
        try store.record(a.reseeded(5))
        #expect(store.all.count == 3, "the same document again is no new entry")
        #expect(HistoryStore(fileURL: url).all.map(\.wallpaper) == store.all.map(\.wallpaper))
        try store.remove(store.all[0])
        #expect(store.all.count == 2)
        try store.removeAll()
        #expect(store.all.isEmpty && HistoryStore(fileURL: url).all.isEmpty)
    }
}
