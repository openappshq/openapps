import Foundation
@testable import MacPaperCore
import Testing

/// Documents from outside — a shared link, a hand-edited favorites file —
/// either decode to something every generator can render, or are refused.
/// Nothing that decodes may trap or spin.
@Suite("Document fuzzing")
struct DocumentFuzzTests {
    static let renderer = WallpaperRenderer()
    static let size = PixelSize(width: 48, height: 30)

    @Test("The reviewer's mesh with no colors, and its neighbours, are refused or render")
    func craftedDocuments() throws {
        let empty = Data("{\"version\":2,\"generator\":{\"type\":\"mesh\",\"columns\":2,\"rows\":2,\"colors\":[],\"jitter\":0.5,\"softness\":0.5},\"seed\":\"1\"}".utf8)
        #expect(throws: DecodingError.self) { try Wallpaper.fromJSON(empty) }
        let code = ShareCode.base64url(ShareCode.compress(empty))
        #expect(throws: ShareCode.DecodeError.corrupt) { try ShareCode.decode(code) }
        let cases: [String] = [
            "{\"generator\":{\"type\":\"mesh\",\"columns\":0,\"rows\":-3,\"colors\":[\"#000000\",\"#FFFFFF\"]},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"mesh\",\"columns\":100000,\"rows\":2,\"colors\":[\"#000000\",\"#FFFFFF\"]},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"gradient\",\"kind\":\"linear\",\"angle\":1e308,\"stops\":[{\"position\":0,\"color\":\"#000000\"},{\"position\":1,\"color\":\"#FFFFFF\"}]},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"gradient\",\"kind\":\"radial\",\"center\":{\"x\":-5,\"y\":9},\"stops\":[{\"position\":0,\"color\":\"#000000\"},{\"position\":1,\"color\":\"#FFFFFF\"}]},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"gradient\",\"kind\":\"linear\",\"stops\":[]},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"gradient\",\"kind\":\"linear\",\"stops\":[{\"position\":\"NaN\",\"color\":\"#000000\"},{\"position\":1,\"color\":\"#FFFFFF\"}]},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"pattern\",\"kind\":\"dots\",\"foreground\":\"#000000\",\"background\":\"#FFFFFF\",\"scale\":1e300},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"pixelize\",\"blockSize\":-8},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"pixelize\",\"blockSize\":16,\"paletteSize\":99999999},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"dither\",\"mode\":\"halftone\",\"cell\":0},\"seed\":\"1\"}",
            "{\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"1\",\"finish\":{\"topShade\":-1e10}}",
            "{\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"1\",\"finish\":{\"tint\":{\"color\":\"#000000\",\"amount\":7}}}",
            "{\"generator\":{\"type\":\"solid\",\"color\":\"#000000\"},\"seed\":\"1\",\"finish\":{\"gradientMap\":[]}}",
        ]
        for json in cases {
            #expect(throws: DecodingError.self, Comment(rawValue: json)) { try Wallpaper.fromJSON(Data(json.utf8)) }
        }
    }

    /// 200 seeded mutations of every reference document: numbers replaced
    /// by extremes, arrays emptied, keys dropped. Whatever decodes renders
    /// on both sides and as time-of-day frames at a small size.
    @Test("Random mutations never crash generation")
    func mutations() throws {
        let references: [Wallpaper] = [
            .starter,
            Wallpaper(generator: .mesh(MeshParameters(columns: 3, rows: 3, colors: Palettes.all[2])), seed: 2, composition: .emerge),
            Wallpaper(generator: .pattern(PatternParameters(kind: .lines, foreground: .white, background: .black, scale: 20, angle: 30)), seed: 3, finish: Finish(tint: Tint(color: .white, amount: 0.3), duotone: Duotone(shadow: .black, highlight: .white), gradientMap: [ColorStop(position: 0, color: .black), ColorStop(position: 1, color: .white)], topShade: 0.4), pair: .lightDark, composition: .contours),
            Wallpaper(generator: .pixelize(PixelizeParameters(source: nil, blockSize: 8, paletteSize: 4, fit: .fit)), seed: 4, composition: .pill),
            Wallpaper(generator: .dither(DitherParameters(source: nil, mode: .ascii, cell: 6)), seed: 5, pair: .timeOfDay(frames: 4)),
        ]
        var generator = SeededGenerator(seed: 0xF022)
        let extremes = ["-1", "0", "1e308", "-1e308", "99999999999", "1.5", "-0.25", "0.999", "\"NaN\"", "null", "[]", "{}", "\"x\""]
        var decoded = 0, refused = 0
        for _ in 0..<200 {
            let reference = references[Int(generator.next() % UInt64(references.count))]
            var json = String(decoding: try reference.jsonData(), as: UTF8.self)
            // Replace a few numbers with extremes; sometimes empty an array or drop a key.
            // Numbers right after a colon (":135", ":0.5"), with the colon kept.
            let numbers = json.ranges(of: /:-?\d+(\.\d+)?(e-?\d+)?/)
            if !numbers.isEmpty {
                let range = numbers[Int(generator.next() % UInt64(numbers.count))]
                json.replaceSubrange(range, with: ":" + extremes[Int(generator.next() % UInt64(extremes.count))])
            }
            if generator.nextUnit() < 0.3, let arrayRange = json.firstRange(of: /\[[^\]]*\]/) {
                json.replaceSubrange(arrayRange, with: "[]")
            }
            if generator.nextUnit() < 0.3, let keyRange = json.firstRange(of: /"(columns|rows|kind|stops|colors|cell|mode|blockSize)":/) {
                json.replaceSubrange(keyRange, with: "\"gone\":")
            }
            guard let document = try? Wallpaper.fromJSON(Data(json.utf8)) else {
                refused += 1
                continue
            }
            decoded += 1
            let context = RenderContext(size: Self.size, notch: NotchSpec.virtual, menuBarStrip: 2)
            _ = Self.renderer.render(document, side: .light, context: context)
            _ = Self.renderer.render(document, side: .dark, context: context)
            _ = Self.renderer.renderFrames(document, frames: 4, context: context)
            _ = WallpaperExport.svg(document, size: Self.size, renderer: Self.renderer)
            // And the round trip through a share link.
            let link = try ShareCode.url(for: document)
            #expect(try ShareCode.decode(url: link) == document)
        }
        #expect(decoded > 0 && refused > 0, "decoded \(decoded), refused \(refused)")
    }

    @Test("A favorites or applied file with one bad document keeps the others")
    func lossyFiles() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let favorites = directory.url.appendingPathComponent("favorites.json")
        let good = String(decoding: try Wallpaper.starter.jsonData(), as: UTF8.self)
        let bad = "{\"generator\":{\"type\":\"mesh\",\"columns\":2,\"rows\":2,\"colors\":[]},\"seed\":\"1\"}"
        try Data("{\"version\":1,\"favorites\":[{\"id\":\"B2E7B4D2-6B7E-4E26-9D0C-4B3B7A0E4C11\",\"wallpaper\":\(bad),\"addedAt\":\"2026-09-16T00:00:00Z\"},{\"id\":\"B2E7B4D2-6B7E-4E26-9D0C-4B3B7A0E4C12\",\"wallpaper\":\(good),\"addedAt\":\"2026-09-16T00:00:00Z\"}]}".utf8).write(to: favorites)
        #expect(FavoritesStore(fileURL: favorites).all.map(\.wallpaper) == [.starter])
        let applied = directory.url.appendingPathComponent("applied.json")
        try Data("{\"byDisplay\":{\"1\":\(bad),\"2\":\(good)},\"draft\":\(bad)}".utf8).write(to: applied)
        let state = AppliedStore(fileURL: applied).current
        #expect(state.wallpaper(for: 1) == nil && state.wallpaper(for: 2) == .starter && state.draft == nil)
    }
}
