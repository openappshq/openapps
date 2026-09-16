import AppKit
import OpenNotesCore

/// Fonts and colors for the styler's runs, and the one place attributes
/// are applied. Attribute-only: the string is never touched, so no edit
/// path of `NSTextView` is fought (design/products/opennotes.md, "Notes").
/// The look comes from `NoteAppearance`: the note's font at its size, and
/// the ink the paper takes in the appearance.
struct NoteStyler {
    var look: NoteAppearance
    var ink: NSColor
    var secondary: NSColor
    var link: NSColor

    init(look: NoteAppearance, appearance: NSAppearance? = nil) {
        self.look = look
        let dark = (appearance ?? NSApp?.effectiveAppearance)?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ink = look.inkColor(dark: dark)
        secondary = look.inkSecondaryColor(dark: dark)
        link = look.linkColor(dark: dark)
    }

    /// A face on the default paper, for tests and the harness.
    init(face: NoteFace, size: CGFloat = CGFloat(NoteTypeface.defaultSize), appearance: NSAppearance? = nil) {
        self.init(look: NoteAppearance(font: NoteAppearance.Font(.face(face)), size: size), appearance: appearance)
    }

    var size: CGFloat { look.size }

    /// The attributes for plain text: what typing continues in.
    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 2
        return [.font: font(weight: 400, size: size), .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    func attributes(for style: MarkdownLite.TextStyle) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        var weight: CGFloat = 400
        var fontSize = size
        if style.isTitle { weight = 600; fontSize = size + 4 }
        if let heading = style.heading {
            weight = 600
            fontSize = max(fontSize, size + CGFloat(max(0, 4 - heading)) * 1.5)
        }
        if style.isBold { weight = max(weight, 600) }
        var font = font(weight: weight, size: fontSize)
        if style.isItalic {
            // A family with no italic member (the bundled faces among
            // them) gets a slant instead.
            let italic = look.nsFont(size: fontSize, weight: weight, italic: true)
            if italic.fontDescriptor.symbolicTraits.contains(.italic) { font = italic } else { attributes[.obliqueness] = 0.18 }
        }
        if style.isCode {
            font = monoFont(size: fontSize - 1, medium: style.isBold)
            attributes[.backgroundColor] = ink.withAlphaComponent(0.08)
        }
        attributes[.font] = font
        if style.isMarker {
            attributes[.foregroundColor] = secondary
            if style.checkbox != nil {
                attributes[.font] = monoFont(size: fontSize, medium: true)
                attributes[.foregroundColor] = style.checkbox == true ? link : secondary
                attributes[.cursor] = NSCursor.pointingHand
            }
        }
        if style.isChecked, !style.isMarker {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = secondary
        }
        if let url = style.link {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = link
            attributes[.link] = URL(string: url) ?? url
        }
        return attributes
    }

    /// Re-styles the whole storage from the current text. Runs inside its
    /// own editing group; only attributes change, never characters.
    func apply(to storage: NSTextStorage) {
        let text = storage.string
        let runs = MarkdownLite.runs(in: text)
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes, range: whole)
        for run in runs where NSMaxRange(run.range) <= storage.length {
            storage.setAttributes(attributes(for: run.style), range: run.range)
        }
        storage.endEditing()
    }

    private func font(weight: CGFloat, size: CGFloat) -> NSFont {
        look.nsFont(size: size, weight: weight)
    }

    /// Code spans and checkboxes: the note's own font when it is
    /// monospaced, so they sit on its grid; IBM Plex Mono otherwise.
    private func monoFont(size: CGFloat, medium: Bool) -> NSFont {
        if look.isMonospaced { return look.nsFont(size: size, weight: medium ? 600 : 400) }
        return Brand.monoFont(size: size, medium: medium)
    }
}
