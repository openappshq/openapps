import Foundation

/// The little Markdown a sticky understands (design/products/opennotes.md,
/// "Notes"): headings, bold, italic, code, lists, checklists and URLs,
/// styled live without changing a character. The parser reads a whole
/// text and reports styled runs over UTF-16 ranges; the app maps each
/// run's `TextStyle` to fonts and colors. Nothing here knows AppKit.
nonisolated public enum MarkdownLite {
    /// What one stretch of text is, by the markers around it. Markers
    /// themselves are runs with `isMarker` (dimmed, still visible).
    public struct TextStyle: Hashable, Sendable {
        /// The first non-empty line: the note's title.
        public var isTitle = false
        /// 1–3 for a `#` heading line (the title line may also be one).
        public var heading: Int?
        public var isBold = false
        public var isItalic = false
        public var isCode = false
        /// `#`, `**`, `_`, backticks, list bullets and the checkbox itself.
        public var isMarker = false
        /// A list line: `- `, `* `, `+ ` or `1. `.
        public var isListItem = false
        /// The three characters of a checkbox, `[ ]` or `[x]`.
        public var checkbox: Bool?
        /// The line's checkbox is ticked: the text after it is done.
        public var isChecked = false
        public var link: String?

        public init() {}

        public static let plain = TextStyle()
    }

    public struct Run: Hashable, Sendable {
        public var range: NSRange
        public var style: TextStyle

        public init(range: NSRange, style: TextStyle) {
            self.range = range
            self.style = style
        }
    }

    /// A checklist box in the text: its `[ ]` / `[x]` range and state.
    public struct Checkbox: Hashable, Sendable {
        public var range: NSRange
        public var checked: Bool
        /// The whole line, for the click target.
        public var lineRange: NSRange
    }

    /// How much of a text is styled by default: the editor's budget, in
    /// UTF-16 units. Beyond it the runs are plain (still tiling the text),
    /// so a giant note costs one plain run instead of a style per unit.
    public static let styleLimit = 64_000

    /// The runs covering the whole text, in order, adjacent runs with the
    /// same style merged. An empty text has no runs. Only the first `limit`
    /// units are styled; the rest is one plain run.
    public static func runs(in text: String, limit: Int = styleLimit) -> [Run] {
        let string = text as NSString
        let length = string.length
        guard length > 0 else { return [] }
        let styled = min(length, max(0, limit))
        var styles = [TextStyle](repeating: .plain, count: styled)
        var titleFound = false
        var index = 0
        while index < styled {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            var contentRange = lineRange
            // The line without its terminator, and never past the budget.
            let terminator = string.substring(with: lineRange).hasSuffix("\n") ? 1 : 0
            contentRange.length = min(contentRange.length - terminator, styled - contentRange.location)
            styleLine(string, contentRange, &styles, titleFound: &titleFound)
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        var runs = coalesce(styles)
        if styled < length {
            if runs.last?.style == .plain, let last = runs.last {
                runs[runs.count - 1].range.length = length - last.range.location
            } else {
                runs.append(Run(range: NSRange(location: styled, length: length - styled), style: .plain))
            }
        }
        return runs
    }

    /// Every checkbox in the text, in order.
    public static func checkboxes(in text: String) -> [Checkbox] {
        var result: [Checkbox] = []
        let string = text as NSString
        var index = 0
        while index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let line = string.substring(with: lineRange)
            if let box = checkbox(inLine: line) {
                result.append(Checkbox(range: NSRange(location: lineRange.location + box.offset, length: 3), checked: box.checked, lineRange: lineRange))
            }
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        return result
    }

    /// How far a note's checklist has come (design/products/opennotes.md,
    /// "The deck"): the boxes done over the boxes there are, from the same
    /// parse the styler and the click use — nested items count, `[X]` is
    /// done, a `[ ]` that is not a box (inside a code span, after no list
    /// marker) is not counted. Read from the text, never kept in the file.
    public struct ChecklistProgress: Hashable, Sendable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }

        /// Every box is ticked.
        public var isComplete: Bool { total > 0 && done == total }
        /// 0…1, for the line along the tab.
        public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
        /// "3/7", as the tab shows it.
        public var label: String { "\(done)/\(total)" }
    }

    /// The text's checklist progress; nil when it has no box at all.
    public static func checklistProgress(in text: String) -> ChecklistProgress? {
        let boxes = checkboxes(in: text)
        guard !boxes.isEmpty else { return nil }
        return ChecklistProgress(done: boxes.filter(\.checked).count, total: boxes.count)
    }

    /// The edit that toggles the checkbox whose line contains `location`:
    /// the three-character range and its replacement. Nil when the
    /// location is not on a checklist line.
    public static func toggleCheckbox(in text: String, at location: Int) -> (range: NSRange, replacement: String)? {
        let string = text as NSString
        guard let box = checkboxes(in: text).first(where: { box in
            // The caret at the very end of an unterminated last line counts too.
            let terminated = string.substring(with: box.lineRange).hasSuffix("\n")
            let contentEnd = NSMaxRange(box.lineRange) - (terminated ? 1 : 0)
            return location >= box.lineRange.location && location <= contentEnd
        }) else { return nil }
        return (box.range, box.checked ? "[ ]" : "[x]")
    }

    /// The text with the markers removed, for `.txt` export: heading `#`s,
    /// emphasis and code backticks. List bullets and checkboxes stay, being
    /// plain-text conventions already.
    public static func plainText(_ text: String) -> String {
        let string = text as NSString
        let runs = runs(in: text, limit: Int.max)
        var kept = [Bool](repeating: true, count: string.length)
        // Emphasis, code and heading markers go (a heading's marker includes
        // its trailing space); bullets and checkboxes stay.
        for run in runs where run.style.isMarker && (run.style.isBold || run.style.isItalic || run.style.isCode || run.style.heading != nil) {
            for i in run.range.location..<NSMaxRange(run.range) { kept[i] = false }
        }
        var buffer: [unichar] = []
        for i in 0..<string.length where kept[i] { buffer.append(string.character(at: i)) }
        return String(utf16CodeUnits: buffer, count: buffer.count)
    }

    // MARK: - Lines

    private struct CheckboxMatch {
        let offset: Int
        let checked: Bool
    }

    private static func checkbox(inLine line: String) -> CheckboxMatch? {
        let ns = line as NSString
        guard let bullet = listMarker(ns) else { return nil }
        let after = bullet.location + bullet.length
        guard ns.length >= after + 3 else { return nil }
        let box = ns.substring(with: NSRange(location: after, length: 3))
        // A box must be followed by a space, the end of the line, or the terminator.
        let next = ns.length > after + 3 ? ns.character(at: after + 3) : 32
        guard next == 32 || next == 10 || next == 9 else { return nil }
        switch box {
        case "[ ]": return CheckboxMatch(offset: after, checked: false)
        case "[x]", "[X]": return CheckboxMatch(offset: after, checked: true)
        default: return nil
        }
    }

    /// The range of a list marker at the start of the line (after any
    /// indentation), including its trailing space.
    private static func listMarker(_ line: NSString) -> NSRange? {
        var i = 0
        while i < line.length, line.character(at: i) == 32 || line.character(at: i) == 9 { i += 1 }
        guard i < line.length else { return nil }
        let c = line.character(at: i)
        if c == 45 || c == 42 || c == 43 { // - * +
            guard i + 1 < line.length, line.character(at: i + 1) == 32 else { return nil }
            return NSRange(location: i, length: 2)
        }
        var j = i
        while j < line.length, line.character(at: j) >= 48, line.character(at: j) <= 57 { j += 1 }
        if j > i, j + 1 < line.length, line.character(at: j) == 46, line.character(at: j + 1) == 32 {
            return NSRange(location: i, length: j + 2 - i)
        }
        return nil
    }

    private static func styleLine(_ string: NSString, _ range: NSRange, _ styles: inout [TextStyle], titleFound: inout Bool) {
        guard range.length > 0 else { return }
        let line = string.substring(with: range) as NSString
        let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        var base = TextStyle()
        var inlineStart = 0

        if !isBlank, !titleFound {
            titleFound = true
            base.isTitle = true
        }
        // Heading: 1–3 `#` then a space.
        var hashes = 0
        while hashes < line.length, hashes < 4, line.character(at: hashes) == 35 { hashes += 1 }
        if hashes >= 1, hashes <= 3, hashes < line.length, line.character(at: hashes) == 32 {
            base.heading = hashes
            var marker = base
            marker.isMarker = true
            fill(&styles, range.location, NSRange(location: 0, length: hashes + 1), marker)
            inlineStart = hashes + 1
        } else if let bullet = listMarker(line) {
            base.isListItem = true
            var marker = base
            marker.isMarker = true
            fill(&styles, range.location, bullet, marker)
            inlineStart = NSMaxRange(bullet)
            if let box = checkbox(inLine: line as String) {
                base.isChecked = box.checked
                var boxStyle = base
                boxStyle.isMarker = true
                boxStyle.checkbox = box.checked
                fill(&styles, range.location, NSRange(location: box.offset, length: 3), boxStyle)
                inlineStart = box.offset + 3
            }
        }
        fill(&styles, range.location, NSRange(location: inlineStart, length: line.length - inlineStart), base)
        styleInline(line, from: inlineStart, base: base, offset: range.location, &styles)
    }

    // MARK: - Inline

    private static func styleInline(_ line: NSString, from start: Int, base: TextStyle, offset: Int, _ styles: inout [TextStyle]) {
        let length = line.length
        var i = start
        // Code first: nothing inside backticks is interpreted. One flag per
        // unit of the line, so a line with many spans stays linear.
        var codeFlags = [Bool](repeating: false, count: length)
        while i < length {
            if line.character(at: i) == 96, let close = find(line, 96, from: i + 1, before: length), close > i + 1 {
                for k in i...close { codeFlags[k] = true }
                var code = base
                code.isCode = true
                fill(&styles, offset, NSRange(location: i + 1, length: close - i - 1), code)
                var marker = code
                marker.isMarker = true
                fill(&styles, offset, NSRange(location: i, length: 1), marker)
                fill(&styles, offset, NSRange(location: close, length: 1), marker)
                i = close + 1
            } else {
                i += 1
            }
        }
        func inCode(_ index: Int) -> Bool { index < length && codeFlags[index] }

        // Bold `**` / `__`, then italic `*` / `_`.
        for (double, single) in [(UInt16(42), UInt16(42)), (UInt16(95), UInt16(95))] {
            i = start
            while i + 1 < length {
                if !inCode(i), line.character(at: i) == double, line.character(at: i + 1) == double,
                   i + 2 < length, line.character(at: i + 2) != 32,
                   let close = findPair(line, double, from: i + 2, before: length, inCode: inCode), close > i + 2 {
                    mark(&styles, offset, from: i + 2, to: close, base: base) { $0.isBold = true }
                    markMarker(&styles, offset, NSRange(location: i, length: 2)) { $0.isBold = true }
                    markMarker(&styles, offset, NSRange(location: close, length: 2)) { $0.isBold = true }
                    i = close + 2
                } else {
                    i += 1
                }
            }
            i = start
            while i < length {
                let c = line.character(at: i)
                if c == single, !inCode(i), !styles[offset + i].isMarker,
                   i + 1 < length, line.character(at: i + 1) != 32,
                   (i == 0 || isBoundary(line.character(at: i - 1))),
                   let close = findSingle(line, single, from: i + 1, before: length, inCode: inCode, styles: styles, offset: offset), close > i + 1 {
                    mark(&styles, offset, from: i + 1, to: close, base: base) { $0.isItalic = true }
                    markMarker(&styles, offset, NSRange(location: i, length: 1)) { $0.isItalic = true }
                    markMarker(&styles, offset, NSRange(location: close, length: 1)) { $0.isItalic = true }
                    i = close + 1
                } else {
                    i += 1
                }
            }
        }

        // URLs.
        for scheme in ["https://", "http://"] {
            var search = NSRange(location: start, length: length - start)
            while search.length > 0 {
                let found = line.range(of: scheme, options: [.caseInsensitive], range: search)
                guard found.location != NSNotFound else { break }
                var end = NSMaxRange(found)
                while end < length, !isURLTerminator(line.character(at: end)) { end += 1 }
                // Trailing punctuation belongs to the sentence, not the link.
                while end > NSMaxRange(found), [46, 44, 41, 59, 58, 33, 63].contains(line.character(at: end - 1)) { end -= 1 }
                if end > NSMaxRange(found), !inCode(found.location) {
                    let url = line.substring(with: NSRange(location: found.location, length: end - found.location))
                    for k in found.location..<end { styles[offset + k].link = url }
                }
                search = NSRange(location: end, length: length - end)
            }
        }
    }

    private static func isBoundary(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 40 || c == 91 || c == 34 || c == 39 || c == 45 || c == 47 || c == 58
    }

    private static func isURLTerminator(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 60 || c == 62 || c == 34 || c == 39 || c == 96
    }

    private static func find(_ line: NSString, _ c: unichar, from: Int, before: Int) -> Int? {
        var i = from
        while i < before {
            if line.character(at: i) == c { return i }
            i += 1
        }
        return nil
    }

    /// The closing double marker: the two characters preceded by a non-space.
    private static func findPair(_ line: NSString, _ c: unichar, from: Int, before: Int, inCode: (Int) -> Bool) -> Int? {
        var i = from
        while i + 1 < before {
            if line.character(at: i) == c, line.character(at: i + 1) == c, line.character(at: i - 1) != 32, !inCode(i) { return i }
            i += 1
        }
        return nil
    }

    /// The closing single marker: preceded by a non-space, not part of a
    /// double marker, followed by a boundary or the end.
    private static func findSingle(_ line: NSString, _ c: unichar, from: Int, before: Int, inCode: (Int) -> Bool, styles: [TextStyle], offset: Int) -> Int? {
        var i = from
        while i < before {
            if line.character(at: i) == c, line.character(at: i - 1) != 32, !inCode(i), !styles[offset + i].isMarker,
               i + 1 == before || isBoundary(line.character(at: i + 1)) || [46, 44, 41, 59, 58, 33, 63].contains(line.character(at: i + 1)) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func fill(_ styles: inout [TextStyle], _ offset: Int, _ range: NSRange, _ style: TextStyle) {
        guard range.length > 0 else { return }
        for i in range.location..<NSMaxRange(range) where offset + i < styles.count { styles[offset + i] = style }
    }

    private static func mark(_ styles: inout [TextStyle], _ offset: Int, from: Int, to: Int, base: TextStyle, _ change: (inout TextStyle) -> Void) {
        for i in from..<to { change(&styles[offset + i]) }
    }

    private static func markMarker(_ styles: inout [TextStyle], _ offset: Int, _ range: NSRange, _ change: (inout TextStyle) -> Void) {
        for i in range.location..<NSMaxRange(range) {
            styles[offset + i].isMarker = true
            change(&styles[offset + i])
        }
    }

    private static func coalesce(_ styles: [TextStyle]) -> [Run] {
        guard !styles.isEmpty else { return [] }
        var runs: [Run] = []
        var start = 0
        for i in 1...styles.count {
            if i == styles.count || styles[i] != styles[start] {
                runs.append(Run(range: NSRange(location: start, length: i - start), style: styles[start]))
                start = i
            }
        }
        return runs
    }
}
