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
    @Test("About fifty presets, uniquely named, three to five colors each, in gamut and distinct")
    func presets() {
        #expect(PresetPalettes.all.count >= 48)
        #expect(Set(PresetPalettes.all.map(\.name)).count == PresetPalettes.all.count)
        var seen: Set<[String]> = []
        for preset in PresetPalettes.all {
            let colors = preset.colors
            #expect((3...5).contains(colors.count), Comment(rawValue: preset.name))
            for color in colors {
                #expect((0...1).contains(color.red) && (0...1).contains(color.green) && (0...1).contains(color.blue), Comment(rawValue: preset.name))
            }
            #expect(seen.insert(colors.map(\.hexString)).inserted, "\(preset.name) repeats another preset")
            #expect(colors.first!.luminance < colors.last!.luminance, "\(preset.name) runs dark to light")
        }
    }

    @Test("A document's colors name their preset, a subset included; anything else is Custom")
    func matching() {
        let sea = PresetPalettes.named("Sea")!
        #expect(PresetPalettes.matching(sea.colors)?.name == "Sea")
        #expect(PresetPalettes.matching(Array(sea.colors.prefix(2)))?.name == "Sea", "a two-color generator on the palette")
        #expect(PresetPalettes.matching([sea.colors[0]]) == nil, "one color is no palette")
        #expect(PresetPalettes.name(for: [RGBAColor(hex: 0x123456), RGBAColor(hex: 0x654321)]) == "Custom")
        #expect(PresetPalettes.named("Nope") == nil)
    }

    @Test("Starters are complete documents on preset palettes, never a base layer or an image")
    func starters() {
        #expect(StarterRecipes.all.count >= 6)
        #expect(Set(StarterRecipes.all.map(\.name)).count == StarterRecipes.all.count)
        for starter in StarterRecipes.all {
            #expect(!starter.wallpaper.generator.kind.isBaseLayer, Comment(rawValue: starter.name))
            #expect(!starter.wallpaper.generator.kind.needsSource, Comment(rawValue: starter.name))
            #expect(PresetPalettes.matching(starter.wallpaper.generator.colors) != nil, "\(starter.name) is on a preset")
            #expect((try? starter.wallpaper.jsonData())?.isEmpty == false)
        }
    }

    /// The documents a preset lands in: the looks the panel and Shuffle make.
    static let contexts: [(String, @Sendable (PresetPalette) -> Wallpaper)] = [
        ("mesh emerge", { Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 2, colors: $0.colors, jitter: 0.6, softness: 0.5)), seed: 42, grain: 0.08, pair: .lightDark, composition: .emerge) }),
        ("mesh busy", { Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: $0.colors, jitter: 0.9, softness: 0.3)), seed: 7) }),
        ("dots", { Wallpaper(generator: .pattern(PatternParameters(kind: .dots, foreground: $0.colors.last!, background: $0.colors[0], scale: 48)), seed: 3, grain: 0.1) }),
        ("lines", { Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: $0.colors.last!, background: $0.colors[1], scale: 40, angle: 45)), seed: 5) }),
    ]

    @Test("Every preset, in every context, reads on both sides once lifted; the lift is the smallest shade that does")
    func presetsRead() {
        let renderer = WallpaperRenderer()
        for preset in PresetPalettes.all {
            for (name, make) in Self.contexts {
                let lifted = make(preset).liftingMenuBar(renderer: renderer)
                for side in Side.allCases {
                    #expect(lifted.menuBarReads(side: side, renderer: renderer), "\(preset.name) · \(name) · \(side)")
                }
                if lifted.finish.topShade > 0 {
                    var lower = lifted
                    lower.finish.topShade = max(0, lifted.finish.topShade - 0.1)
                    #expect(!Side.allCases.allSatisfy { lower.menuBarReads(side: $0, renderer: renderer) }, "\(preset.name) · \(name): a tenth less would not read")
                }
            }
        }
    }

    @Test("Every starter reads on both sides as shipped")
    func startersRead() {
        let renderer = WallpaperRenderer()
        for starter in StarterRecipes.all {
            for side in Side.allCases {
                #expect(starter.wallpaper.menuBarReads(side: side, renderer: renderer), "\(starter.name) · \(side)")
            }
        }
        #expect(StarterRecipes.all.map(\.name) == StarterRecipes.raw.map(\.name))
    }

    @Test("The panel lists the image and field generators; flat and gradient are the base layer; Shuffle never makes a base layer")
    func order() {
        #expect(GeneratorKind.panelOrder == [.dither, .mesh, .pattern, .pixelize])
        #expect(GeneratorKind.baseLayers == [.solid, .gradient])
        #expect(!GeneratorKind.shuffleable.contains { $0.isBaseLayer })
        var generator = SeededGenerator(seed: 9)
        for _ in 0..<40 { #expect(!Wallpaper.random(using: &generator).generator.kind.isBaseLayer) }
    }
}

@Suite("Pins")
struct PinTests {
    static let mesh = Wallpaper(generator: .mesh(MeshParameters(columns: 4, rows: 2, colors: PresetPalettes.named("Sea")!.colors, jitter: 0.9, softness: 0.2)), seed: 7, grain: 0.3, finish: Finish(topShade: 0.5), pair: .lightDark, composition: .emerge)
    static let pattern = Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: .white, background: .black, scale: 120, angle: 45)), seed: 99)

    @Test("Nothing pinned: the candidate is untouched")
    func none() {
        #expect(PinnedParameters().carry(from: Self.mesh, into: Self.pattern) == Self.pattern)
    }

    @Test("Document-wide pins copy their value and leave the generator alone")
    func documentWide() {
        let pins = PinnedParameters([.seed, .grain, .topShade, .composition, .pair])
        let out = pins.carry(from: Self.mesh, into: Self.pattern)
        #expect(out.generator == Self.pattern.generator)
        #expect(out.seed == 7 && out.grain == 0.3 && out.finish.topShade == 0.5 && out.composition == .emerge && out.pair == .lightDark)
    }

    @Test("The palette pin recolors the candidate in the current colors")
    func palette() {
        let out = PinnedParameters([.palette]).carry(from: Self.mesh, into: Self.pattern)
        guard case .pattern(let p) = out.generator else { Issue.record("not a pattern"); return }
        let sea = PresetPalettes.named("Sea")!.colors
        #expect(p.background == sea[0] && p.foreground == sea[3])
        #expect(p.kind == .lines && p.scale == 120, "only the colors changed")
    }

    @Test("A generator parameter pin keeps the generator, with that parameter")
    func generatorParameter() {
        let out = PinnedParameters([.meshJitter]).carry(from: Self.mesh, into: Self.pattern)
        guard case .mesh(let p) = out.generator else { Issue.record("not a mesh"); return }
        #expect(p.jitter == 0.9)
        #expect(p.softness == 0.5 && p.columns == 3, "the rest is the default, not the current")
        #expect(p.colors == [.black, .white], "the candidate's own colors carried into the mesh")
        #expect(PinnedParameters([.meshJitter]).keepsGenerator(of: Self.mesh))
        #expect(!PinnedParameters([.meshJitter]).keepsGenerator(of: Self.pattern), "a mesh pin says nothing about a pattern")
        #expect(PinnedParameters([.generator]).carry(from: Self.pattern, into: Self.mesh).generator.kind == .pattern)
    }

    @Test("Same kind: every pinned parameter copies over, the others stay random")
    func sameKind() {
        let other = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 5, colors: [.black, .white], jitter: 0.1, softness: 0.8)), seed: 1)
        let out = PinnedParameters([.meshGrid, .meshSoftness]).carry(from: Self.mesh, into: other)
        guard case .mesh(let p) = out.generator else { Issue.record("not a mesh"); return }
        #expect(p.columns == 4 && p.rows == 2 && p.softness == 0.2 && p.jitter == 0.1)
    }

    @Test("Framing pins keep an image generator and its crop")
    func framing() {
        let reference = ImageReference(fileName: "0123456789abcdef.png", contentHash: String(repeating: "a", count: 64))
        let current = Wallpaper(generator: .pixelize(PixelizeParameters(source: reference, blockSize: 40, fit: .fit, focus: Point(x: 0.2, y: 0.8))), seed: 3)
        let out = PinnedParameters([.framing]).carry(from: current, into: Self.pattern)
        guard case .pixelize(let p) = out.generator else { Issue.record("not pixelize"); return }
        #expect(p.source == reference && p.fit == .fit && p.focus == Point(x: 0.2, y: 0.8))
        #expect(p.blockSize == 16, "unpinned: the default")
    }

    @Test("Pins carry per side: a value pinned on an edited dark side survives as the dark side's, the light side keeps its own")
    func bothSides() {
        var current = Self.mesh
        // The light side at jitter 0.1, the dark side edited by hand to 0.9.
        current.generator = .mesh(MeshParameters(columns: 3, rows: 3, colors: [.black, .white], jitter: 0.1, softness: 0.5))
        current.darkGenerator = .mesh(MeshParameters(columns: 3, rows: 3, colors: [RGBAColor(hex: 0x102030), RGBAColor(hex: 0x405060)], jitter: 0.9, softness: 0.4))
        let candidate = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: PresetPalettes.named("Sea")!.colors, jitter: 0.5, softness: 0.5)), seed: 3)
        let out = PinnedParameters([.meshJitter]).carry(from: current, into: candidate)
        guard case .mesh(let light) = out.generator, case .mesh(let dark)? = out.darkGenerator else { Issue.record("sides missing"); return }
        #expect(light.jitter == 0.1, "the light side keeps the light side's jitter")
        #expect(dark.jitter == 0.9, "the dark side keeps the dark side's jitter")
        #expect(dark.colors == candidate.generator.darkened().colors, "the dark side is the candidate's derived dark side otherwise")
        #expect(out.generator(for: .dark) == out.darkGenerator)
        // The palette pinned: each side's own colors.
        let palette = PinnedParameters([.palette]).carry(from: current, into: candidate)
        #expect(palette.generator.colors == [.black, .white])
        #expect(palette.darkGenerator?.colors == [RGBAColor(hex: 0x102030), RGBAColor(hex: 0x405060)])
        // No custom dark side: the candidate's stays derived from the carried light side.
        let derived = PinnedParameters([.meshJitter]).carry(from: Self.mesh, into: candidate)
        #expect(derived.darkGenerator == nil)
        if case .mesh(let p) = derived.generator(for: .dark) { #expect(p.jitter == 0.9) } else { Issue.record("not a mesh") }
    }

    @Test("Pins round-trip as JSON and every pin has a title and a home")
    func codable() throws {
        let pins = PinnedParameters([.seed, .ditherCell])
        let data = try JSONEncoder().encode(pins)
        #expect(try JSONDecoder().decode(PinnedParameters.self, from: data) == pins)
        for pin in ParameterPin.allCases {
            #expect(!pin.title.isEmpty)
        }
        #expect(ParameterPin.ditherCell.generatorKind == .dither && ParameterPin.grain.generatorKind == nil)
        var toggled = pins
        toggled.toggle(.seed)
        #expect(!toggled.contains(.seed) && toggled.contains(.ditherCell))
    }
}

@Suite("Library and history")
struct LibraryStoreTests {
    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macpaper-library-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A favorite carries a name, is titled from its palette and generator without one, and old files decode")
    func names() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoritesStore(fileURL: directory.appendingPathComponent("favorites.json"))
        let sea = Wallpaper(generator: .mesh(MeshParameters(columns: 2, rows: 2, colors: PresetPalettes.named("Sea")!.colors)), seed: 1)
        let saved = try store.add(sea)
        #expect(saved.name == nil && saved.title == "Sea · Mesh")
        #expect(saved.subtitle == "Mesh · seed 1")
        let renamed = try store.add(sea, name: "Deep end")
        #expect(renamed.id == saved.id && renamed.title == "Deep end")
        #expect(try store.add(sea, name: "  ").title == "Deep end", "blank keeps the name")
        try store.rename(renamed, to: nil)
        #expect(store.all[0].title == "Sea · Mesh")
        // A file from before names.
        let old = """
        {"version":1,"favorites":[{"id":"\(UUID().uuidString)","addedAt":"2026-09-16T00:00:00Z","wallpaper":\(String(decoding: try Wallpaper.starter.jsonData(), as: UTF8.self))}]}
        """
        let oldURL = directory.appendingPathComponent("old.json")
        try Data(old.utf8).write(to: oldURL)
        let reloaded = FavoritesStore(fileURL: oldURL)
        #expect(reloaded.all.count == 1 && reloaded.all[0].name == nil && reloaded.all[0].title == "Custom · Gradient")
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
