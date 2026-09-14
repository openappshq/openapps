import CoreText
import Darwin
import Foundation
import OpenReactionCore
import os

/// Whether the system emoji font draws an emoji as a single glyph.
///
/// An emoji newer than the installed font either maps to the missing glyph or,
/// for ZWJ sequences, falls apart into several component glyphs. Laying the
/// string out with Apple Color Emoji and requiring exactly one run with one
/// real glyph from that font catches both, including skin-tone modifiers,
/// flags and keycaps.
final class EmojiRenderability {
    private let font: CTFont?

    init() {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        self.font = (CTFontCopyPostScriptName(font) as String) == "AppleColorEmoji" ? font : nil
    }

    /// False when the emoji font is unavailable; callers fall back to version checks.
    var canInspectFont: Bool { font != nil }

    func isRenderable(_ emoji: String) -> Bool {
        guard let font else { return true }
        let attributed = NSAttributedString(string: emoji, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        guard CTLineGetGlyphCount(line) == 1,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun],
              runs.count == 1 else { return false }
        let run = runs[0]
        if let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] {
            // CTFont is a CF type; the dictionary value is always one when present.
            guard (CTFontCopyPostScriptName(runFont as! CTFont) as String) == "AppleColorEmoji" else { return false }
        }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph != 0
    }
}

/// Builds the emoji catalog at launch: system names when available, gemoji
/// shortcodes, and the render check, with render results cached per OS build.
enum EmojiCatalogLoader {
    struct Result: Sendable {
        let catalog: EmojiCatalog
        let summary: String
    }

    private static let log = Logger(subsystem: "com.openappshq.openreaction", category: "emoji-data")
    private static let cacheKey = "renderSupportCache"

    static func load() throws -> Result {
        let started = ContinuousClock.now
        let gemoji = try EmojiDatabase.bundled()
        let apple = AppleEmojiData.load()
        let renderability = EmojiRenderability()
        let build = osBuild()

        var cache = RenderCache.load(key: cacheKey, build: build)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let gemojiByEmoji = Dictionary(gemoji.entries.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })

        let catalog = EmojiCatalog.build(apple: apple, gemoji: gemoji) { emoji in
            if let cached = cache.results[emoji] { return cached }
            let supported: Bool
            if renderability.canInspectFont {
                supported = renderability.isRenderable(emoji)
            } else if let entry = gemojiByEmoji[emoji] {
                supported = EmojiDatabase.isSupported(entry, onMacOS: version)
            } else {
                supported = true
            }
            cache.results[emoji] = supported
            return supported
        }
        cache.save(key: cacheKey)

        let elapsed = ContinuousClock.now - started
        let summary = "\(catalog.source) · \(catalog.records.count) emoji · \(catalog.unsupportedCount) hidden (not drawable on this Mac) · macOS build \(build)"
        #if DEBUG
        log.debug("Emoji data: \(summary, privacy: .public) in \(elapsed, privacy: .public)")
        #endif
        return Result(catalog: catalog, summary: summary)
    }

    private static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Render results keyed by emoji, valid for one OS build (the emoji font
    /// only changes with system updates).
    private struct RenderCache: Codable {
        var build: String
        var results: [String: Bool]

        static func load(key: String, build: String) -> RenderCache {
            if let data = UserDefaults.standard.data(forKey: key),
               let cache = try? JSONDecoder().decode(RenderCache.self, from: data),
               cache.build == build {
                return cache
            }
            return RenderCache(build: build, results: [:])
        }

        func save(key: String) {
            if let data = try? JSONEncoder().encode(self) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
