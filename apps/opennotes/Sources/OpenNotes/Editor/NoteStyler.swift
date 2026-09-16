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
    /// How `=` lines read and write numbers: the user's locale.
    var arithmeticFormat: Arithmetic.Format

    init(look: NoteAppearance, appearance: NSAppearance? = nil, locale: Locale = .current) {
        self.look = look
        let dark = (appearance ?? NSApp?.effectiveAppearance)?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ink = look.inkColor(dark: dark)
        secondary = look.inkSecondaryColor(dark: dark)
        link = look.linkColor(dark: dark)
        arithmeticFormat = Arithmetic.Format(locale: locale)
    }

    /// A face on the default paper, for tests and the harness.
    init(face: NoteFace, size: CGFloat = CGFloat(NoteTypeface.defaultSize), appearance: NSAppearance? = nil, locale: Locale = .current) {
        self.init(look: NoteAppearance(font: NoteAppearance.Font(.face(face)), size: size), appearance: appearance, locale: locale)
    }

    var size: CGFloat { look.size }

    /// The attributes for plain text: what typing continues in.
    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 2
        return [.font: font(weight: 400, size: size), .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    /// What an `=` line's answer is drawn in, after the line: the face at
    /// the text size, in the secondary color.
    var answerAttributes: [NSAttributedString.Key: Any] {
        [.font: font(weight: 400, size: size), .foregroundColor: secondary]
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
            // The `.link` attribute names the target for accessibility; the
            // text view decides what a click does (⌘-click opens, a plain
            // click places the caret).
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = link
            attributes[.link] = LinkTarget.url(for: url) ?? url
        }
        return attributes
    }

    /// Re-styles the whole storage from the current text. Runs inside its
    /// own editing group; only attributes change, never characters. An
    /// old answer after an `=` reads in the secondary color, struck
    /// through once it no longer matches (the fresh one is drawn after it).
    func apply(to storage: NSTextStorage) {
        let text = storage.string
        let runs = MarkdownLite.runs(in: text)
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes, range: whole)
        for run in runs where NSMaxRange(run.range) <= storage.length {
            storage.setAttributes(attributes(for: run.style), range: run.range)
        }
        for answer in Arithmetic.answers(in: text, format: arithmeticFormat) {
            guard let old = answer.oldAnswerRange, NSMaxRange(old) <= storage.length else { continue }
            storage.addAttributes([.foregroundColor: secondary], range: old)
            if answer.isStale { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: old) }
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

    /// The styled text as the preview harness draws it (`ImageRenderer`
    /// draws no text view): the runs applied, and each `=` line's fresh
    /// answer put after the line, the way the editor draws it. Preview
    /// only — the editor never writes an answer into the text.
    func previewAttributed(_ text: String) -> AttributedString {
        let storage = NSTextStorage(string: text)
        apply(to: storage)
        for answer in Arithmetic.answers(in: text, format: arithmeticFormat).reversed() where answer.needsDrawing {
            let drawn = NSAttributedString(string: "  " + answer.text, attributes: answerAttributes)
            storage.insert(drawn, at: NSMaxRange(answer.lineRange))
        }
        return AttributedString(storage)
    }
}
