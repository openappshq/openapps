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

        // Links, outside code.
        for link in links(inLine: line, from: start, inCode: inCode) {
            for k in link.range.location..<NSMaxRange(link.range) { styles[offset + k].link = link.target }
        }
    }

    // MARK: - Links

    /// A link found in the text: underlined live, opened with ⌘-click,
    /// named by the hover chip. Never stored: the text keeps what was typed.
    public struct Link: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// `http://`, `https://` or a bare `www.` address.
            case web
            /// `mailto:`.
            case mail
            /// `file:///`.
            case file
            /// `~/…`, a path under the home folder.
            case path
        }

        public var range: NSRange
        public var kind: Kind
        /// The address as typed.
        public var text: String
        /// What to open: `https://` put before a bare `www.`, otherwise the
        /// text; a `~/` path is left for the app to expand.
        public var target: String
        /// What the hover chip says: the host, the mailbox, the file name.
        public var display: String
    }

    /// Every link in the text, in order, code spans excluded: `http(s)://`,
    /// `www.`, `mailto:`, `file:///` and `~/` paths, ending at whitespace
    /// or a quote, without the sentence's trailing punctuation and without
    /// a closing bracket the link did not open. Only the first `limit`
    /// units are read (the editor's styling budget), so a giant note costs
    /// one pass, never more.
    public static func links(in text: String, limit: Int = styleLimit) -> [Link] {
        let string = text as NSString
        var result: [Link] = []
        var index = 0
        let end = min(string.length, max(0, limit))
        while index < end {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let terminator = string.substring(with: lineRange).hasSuffix("\n") ? 1 : 0
            // A line past the budget is read up to it.
            let contentLength = min(lineRange.length - terminator, end - lineRange.location)
            let line = string.substring(with: NSRange(location: lineRange.location, length: contentLength)) as NSString
            let code = codeFlags(line)
            for var link in links(inLine: line, from: 0, inCode: { $0 < code.count && code[$0] }) {
                link.range.location += lineRange.location
                result.append(link)
            }
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        return result
    }

    /// The link whose range holds `location` (the caret, a click).
    public static func link(in text: String, at location: Int, limit: Int = styleLimit) -> Link? {
        links(in: text, limit: limit).first { location >= $0.range.location && location <= NSMaxRange($0.range) }
    }

    private static let linkPrefixes: [(String, Link.Kind)] = [
        ("https://", .web), ("http://", .web), ("www.", .web), ("mailto:", .mail), ("file:///", .file), ("~/", .path),
    ]

    private static func links(inLine line: NSString, from start: Int, inCode: (Int) -> Bool) -> [Link] {
        let length = line.length
        var found: [Link] = []
        for (prefix, kind) in linkPrefixes {
            var search = NSRange(location: start, length: length - start)
            while search.length > 0 {
                let match = line.range(of: prefix, options: [.caseInsensitive], range: search)
                guard match.location != NSNotFound else { break }
                search = NSRange(location: NSMaxRange(match), length: length - NSMaxRange(match))
                // A link starts a word: at the line's start or after a boundary.
                guard match.location == start || isLinkBoundary(line.character(at: match.location - 1)), !inCode(match.location) else { continue }
                var end = NSMaxRange(match)
                while end < length, !isURLTerminator(line.character(at: end)) { end += 1 }
                end = trimLinkEnd(line, from: match.location, to: end)
                guard end > NSMaxRange(match) else { continue }
                let range = NSRange(location: match.location, length: end - match.location)
                // `www.` needs a host with a dot after it; a path needs a name.
                let text = line.substring(with: range)
                if kind == .web, prefix == "www.", !text.dropFirst(4).contains(".") { continue }
                found.append(Link(range: range, kind: kind, text: text, target: target(for: text, kind: kind, prefix: prefix), display: display(for: text, kind: kind)))
                search = NSRange(location: end, length: length - end)
            }
        }
        // Prefixes overlap (`https://www.`): the earliest, longest wins.
        found.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var kept: [Link] = []
        for link in found where kept.last.map({ link.range.location >= NSMaxRange($0.range) }) ?? true {
            kept.append(link)
        }
        return kept
    }

    /// Trailing punctuation belongs to the sentence, and a closing bracket
    /// the link did not open belongs to the text around it. One pass over
    /// the link counts the brackets; the trim then walks back once, so a
    /// link followed by a wall of `)` costs its length, not its square.
    private static func trimLinkEnd(_ line: NSString, from start: Int, to end: Int) -> Int {
        var parens = 0
        var squares = 0
        for i in start..<end {
            switch line.character(at: i) {
            case 40: parens += 1
            case 41: parens -= 1
            case 91: squares += 1
            case 93: squares -= 1
            default: break
            }
        }
        var end = end
        while end > start {
            let last = line.character(at: end - 1)
            if [46, 44, 59, 58, 33, 63].contains(last) { // . , ; : ! ?
                end -= 1
                continue
            }
            if last == 41, parens < 0 { // an unopened )
                parens += 1
                end -= 1
                continue
            }
            if last == 93, squares < 0 { // an unopened ]
                squares += 1
                end -= 1
                continue
            }
            break
        }
        return end
    }

    private static func target(for text: String, kind: Link.Kind, prefix: String) -> String {
        kind == .web && prefix == "www." ? "https://" + text : text
    }

    private static func display(for text: String, kind: Link.Kind) -> String {
        switch kind {
        case .web:
            var rest = Substring(text)
            if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
            if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            return rest.lowercased()
        case .mail:
            return String(text.dropFirst("mailto:".count).prefix { $0 != "?" })
        case .file, .path:
            var path = kind == .file ? String(text.dropFirst("file://".count)) : text
            if kind == .file { path = path.removingPercentEncoding ?? path }
            while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return name.isEmpty ? path : name
        }
    }

    /// What may come right before a link: a space, an opening bracket, a
    /// quote, or a marker character.
    private static func isLinkBoundary(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 40 || c == 91 || c == 60 || c == 34 || c == 39 || c == 42 || c == 95 || c == 96
    }

    /// One flag per unit of the line: inside a code span (the backticks
    /// included), where nothing is interpreted.
    private static func codeFlags(_ line: NSString) -> [Bool] {
        let length = line.length
        var flags = [Bool](repeating: false, count: length)
        var i = 0
        while i < length {
            if line.character(at: i) == 96, let close = find(line, 96, from: i + 1, before: length), close > i + 1 {
                for k in i...close { flags[k] = true }
                i = close + 1
            } else {
                i += 1
            }
        }
        return flags
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
