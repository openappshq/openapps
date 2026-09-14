import CoreText
import Foundation
import OpenReactionCore

/// Whether the system emoji font draws an emoji as a single glyph.
///
/// An emoji newer than the installed font either maps to the missing glyph or,
/// for ZWJ sequences, falls apart into several component glyphs. Laying the
/// string out with Apple Color Emoji and requiring exactly one real glyph from
/// that font catches both cases.
enum EmojiRenderability {
    static func filter(_ database: EmojiDatabase) -> EmojiDatabase {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        guard (CTFontCopyPostScriptName(font) as String) == "AppleColorEmoji" else {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return database.filtered { EmojiDatabase.isSupported($0, onMacOS: version) }
        }
        return database.filtered { isRenderable($0.emoji, font: font) }
    }

    static func isRenderable(_ emoji: String, font: CTFont) -> Bool {
        let attributed = NSAttributedString(string: emoji, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        guard CTLineGetGlyphCount(line) == 1,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun],
              let run = runs.first else { return false }

        let attributes = CTRunGetAttributes(run) as NSDictionary
        if let runFont = attributes[kCTFontAttributeName as String] {
            let name = CTFontCopyPostScriptName(runFont as! CTFont) as String
            guard name == "AppleColorEmoji" else { return false }
        }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph != 0
    }
}
