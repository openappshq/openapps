import Foundation

/// Inline arithmetic (design/products/opennotes.md, "Notes"): a line that
/// ends in `=` evaluates the expression before it and the editor draws
/// the answer after the `=`, never into the file. Pure Swift over
/// untrusted text: no `NSExpression`, a bounded input, and garbage gives
/// no answer rather than a crash.
///
/// What it reads: `+ - * / ^ ( )`, `×`, `÷` and `x`, a postfix `%` (`12%`
/// is a twelfth; `80 + 10%` adds a tenth; `12% of 80` is nine point six;
/// a `%` between two operands is the remainder), thousands separators,
/// `k` and `M` after a number, `$`, `€` and `£` on either side of a number
/// and carried to the answer, and `sum`: the amounts on the lines above,
/// up to a blank line. The decimal separator is the format's — the
/// locale's in the app, a fixed one in tests.
nonisolated public enum Arithmetic {
    /// The longest expression evaluated; a longer line has no answer.
    public static let inputLimit = 200
    /// Nesting past this is garbage, not arithmetic.
    public static let depthLimit = 32
    /// Answers at or past this magnitude are "overflow": a sticky counts
    /// money and minutes, not floating-point noise.
    public static let magnitudeLimit: Double = 1e15

    /// How numbers are read and written: the decimal separator and the
    /// grouping separator (`.` and `,` in English, the other way round in
    /// German).
    public struct Format: Hashable, Sendable {
        public var decimalSeparator: String
        public var groupingSeparator: String

        public init(decimalSeparator: String = ".", groupingSeparator: String = ",") {
            self.decimalSeparator = decimalSeparator
            self.groupingSeparator = groupingSeparator
        }

        /// The format of a locale; a locale whose grouping separator is
        /// neither `.` nor `,` (a space, an apostrophe) groups with nothing.
        public init(locale: Locale) {
            let decimal = locale.decimalSeparator ?? "."
            decimalSeparator = decimal == "," ? "," : "."
            let grouping = locale.groupingSeparator ?? (decimalSeparator == "." ? "," : ".")
            groupingSeparator = (grouping == "," || grouping == ".") && grouping != decimalSeparator ? grouping : ""
        }

        public static let point = Format()
        public static let comma = Format(decimalSeparator: ",", groupingSeparator: ".")
    }

    /// An answer: a number, the currency it carries, and whether it is a
    /// share (a bare `10%`, shown as such).
    public struct Value: Hashable, Sendable {
        public var number: Double
        public var currency: String?
        public var isPercent = false

        public init(_ number: Double, currency: String? = nil, isPercent: Bool = false) {
            self.number = number
            self.currency = currency
            self.isPercent = isPercent
        }
    }

    public enum Failure: Error, Hashable, Sendable {
        /// Shown as "÷0".
        case divisionByZero
        /// Not finite, or past `magnitudeLimit`.
        case overflow
    }

    /// The `=` line as the editor sees it: where the line is, the answer's
    /// text, and the old answer the line already carries after the `=` (a
    /// Tab wrote it, or the user typed it), if any.
    public struct Answer: Hashable, Sendable {
        /// The line, terminator excluded.
        public var lineRange: NSRange
        /// The `=` sign.
        public var equalsLocation: Int
        /// What is after the `=`, whitespace trimmed: the old answer. Nil
        /// when there is none.
        public var oldAnswerRange: NSRange?
        /// The answer as it should read now.
        public var text: String
        /// An old answer that no longer matches: dimmed, and the fresh one
        /// drawn after it.
        public var isStale: Bool

        /// The old answer already reads as the answer: nothing to draw.
        public var isCurrent: Bool { oldAnswerRange != nil && !isStale }
        /// The editor draws `text` after the line: no old answer, or a stale one.
        public var needsDrawing: Bool { !isCurrent }

        /// The edit Tab makes: the old answer replaced by the fresh one, or
        /// ` <answer>` in place of whatever whitespace follows the `=`.
        public var commit: (range: NSRange, replacement: String) {
            if let old = oldAnswerRange { return (old, text) }
            let after = equalsLocation + 1
            return (NSRange(location: after, length: NSMaxRange(lineRange) - after), " " + text)
        }
    }

    // MARK: - Lines

    /// Every `=` line of a text whose expression evaluates, in order. A
    /// line's `=` must be the last one of the line, followed by nothing
    /// or an old answer, not part of `==`, `<=`, `>=`, `!=` or `:=`, and
    /// not inside a code span. A list marker, a checkbox or heading marks
    /// before the expression are ignored. Only the first `limit` units are
    /// read (the editor's styling budget); the amounts of a block are read
    /// only when a `sum` asks for them.
    public static func answers(in text: String, format: Format = .point, limit: Int = MarkdownLite.styleLimit) -> [Answer] {
        let string = text as NSString
        var result: [Answer] = []
        /// The block's lines so far, each its text or, for an `=` line
        /// that evaluated, its value.
        var block: [BlockLine] = []
        var index = 0
        while index < min(string.length, max(0, limit)) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let terminator = string.substring(with: lineRange).hasSuffix("\n") ? 1 : 0
            let content = NSRange(location: lineRange.location, length: lineRange.length - terminator)
            let line = string.substring(with: content)
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                block = []
                continue
            }
            if let parsed = parseAnswerLine(line) {
                let expression = String(line[parsed.expression])
                let usesSum = mentionsSum(expression, format: format)
                var sum: Value?
                if usesSum {
                    // Each line's amount is read once, however many sums ask.
                    for i in block.indices { block[i].resolve(format: format) }
                    sum = total(of: block.compactMap { $0.amount })
                }
                if let outcome = evaluateTrailing(expression, format: format, sum: sum) {
                    let rendered = display(outcome, format: format)
                    let old = parsed.oldAnswer.map { NSRange($0, in: line) }
                    let oldText = parsed.oldAnswer.map { String(line[$0]) }
                    result.append(Answer(
                        lineRange: content,
                        equalsLocation: content.location + NSRange(parsed.equals, in: line).location,
                        oldAnswerRange: old.map { NSRange(location: content.location + $0.location, length: $0.length) },
                        text: rendered,
                        isStale: oldText != nil && oldText != rendered
                    ))
                    // A line that sums the block is a total, not an amount.
                    if !usesSum, case .success(let value) = outcome, !value.isPercent { block.append(BlockLine(amount: value)) }
                    continue
                }
            }
            block.append(BlockLine(text: line))
        }
        return result
    }

    /// A line of the block above a `sum`: its amount, read once when asked.
    private struct BlockLine {
        var text: String?
        var amount: Value?
        var resolved: Bool

        init(text: String) {
            self.text = text
            resolved = false
        }

        init(amount: Value) {
            self.amount = amount
            resolved = true
        }

        mutating func resolve(format: Format) {
            guard !resolved else { return }
            resolved = true
            amount = text.flatMap { Arithmetic.amount(in: $0, format: format) }
        }
    }

    /// The `=` line whose range holds `location` (the caret), for Tab.
    public static func answer(in text: String, at location: Int, format: Format = .point, limit: Int = MarkdownLite.styleLimit) -> Answer? {
        answers(in: text, format: format, limit: limit).first { location >= $0.lineRange.location && location <= NSMaxRange($0.lineRange) }
    }

    private struct AnswerLine {
        var expression: Range<String.Index>
        var equals: Range<String.Index>
        var oldAnswer: Range<String.Index>?
    }

    /// The last `=` of the line, what is before it (the expression, with
    /// list, checkbox and heading marks dropped) and what is after it (the
    /// old answer, whitespace trimmed) — when what follows looks like an
    /// answer and not more text.
    private static func parseAnswerLine(_ line: String) -> AnswerLine? {
        guard line.count <= inputLimit, let equals = line.lastIndex(of: "=") else { return nil }
        // `==`, `<=`, `>=`, `!=`, `:=` are somebody's code, not a sum.
        if equals > line.startIndex, "=<>!:".contains(line[line.index(before: equals)]) { return nil }
        // Inside backticks nothing is interpreted.
        guard line[..<equals].filter({ $0 == "`" }).count.isMultiple(of: 2) else { return nil }
        let after = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || looksLikeAnswer(after) else { return nil }
        var start = line.startIndex
        while start < equals, line[start] == " " || line[start] == "\t" { start = line.index(after: start) }
        if let marker = listMarkerEnd(line, from: start) {
            start = marker
            for box in ["[ ] ", "[x] ", "[X] "] where line[start...].hasPrefix(box) { start = line.index(start, offsetBy: 4) }
        } else {
            var hashes = 0
            var cursor = start
            while cursor < equals, line[cursor] == "#", hashes < 4 { hashes += 1; cursor = line.index(after: cursor) }
            if hashes >= 1, hashes <= 3, cursor < equals, line[cursor] == " " { start = line.index(after: cursor) }
        }
        let expression = line[start..<equals].trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty, let expressionStart = line[start..<equals].firstIndex(where: { $0 != " " && $0 != "\t" }) else { return nil }
        let expressionEnd = line.index(expressionStart, offsetBy: expression.count)
        let equalsRange = equals..<line.index(after: equals)
        guard !after.isEmpty else { return AnswerLine(expression: expressionStart..<expressionEnd, equals: equalsRange, oldAnswer: nil) }
        var oldStart = line.index(after: equals)
        while line[oldStart] == " " || line[oldStart] == "\t" { oldStart = line.index(after: oldStart) }
        let oldEnd = line.index(oldStart, offsetBy: after.count)
        return AnswerLine(expression: expressionStart..<expressionEnd, equals: equalsRange, oldAnswer: oldStart..<oldEnd)
    }

    /// `- `, `* `, `+ ` or `1. ` at `start`: the index after the marker.
    private static func listMarkerEnd(_ line: String, from start: String.Index) -> String.Index? {
        guard start < line.endIndex else { return nil }
        let c = line[start]
        let next = line.index(after: start)
        if c == "-" || c == "*" || c == "+" {
            guard next < line.endIndex, line[next] == " " else { return nil }
            return line.index(after: next)
        }
        var cursor = start
        while cursor < line.endIndex, line[cursor].isASCII, line[cursor].isNumber { cursor = line.index(after: cursor) }
        guard cursor > start, cursor < line.endIndex, line[cursor] == "." else { return nil }
        let space = line.index(after: cursor)
        guard space < line.endIndex, line[space] == " " else { return nil }
        return line.index(after: space)
    }

    /// What an old answer can look like: a signed, formatted number with
    /// an optional currency and `%`, or one of the two failure words.
    private static func looksLikeAnswer(_ text: String) -> Bool {
        if text == "÷0" || text == "overflow" { return true }
        var rest = Substring(text)
        if rest.hasPrefix("-") { rest = rest.dropFirst() }
        if let first = rest.first, currencySymbols.contains(first) { rest = rest.dropFirst() }
        if rest.hasSuffix("%") { rest = rest.dropLast() }
        if let last = rest.last, currencySymbols.contains(last) { rest = rest.dropLast() }
        guard let first = rest.first, (first.isASCII && first.isNumber) || first == "." || first == "," else { return false }
        return rest.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," || $0 == " " }
    }

    private static func mentionsSum(_ expression: String, format: Format) -> Bool {
        tokens(in: expression, format: format)?.contains(.sum) ?? false
    }

    // MARK: - Amounts on the lines above

    /// What a line above a `sum` contributes: a line whose whole text is
    /// an expression, its value; any other line, its last number that
    /// stands on its own (`Lunch $12`, `- [x] taxi 8.50`), with its
    /// currency and suffix. Nothing for a line with no number, a time
    /// (`10:30`) or a number glued to a word (`3rd`).
    static func amount(in line: String, format: Format) -> Value? {
        var text = Substring(line)
        while let first = text.first, first == " " || first == "\t" { text = text.dropFirst() }
        if let marker = listMarkerEnd(String(text), from: text.startIndex) {
            text = text[marker...]
            for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text = text.dropFirst(4) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= inputLimit, !trimmed.isEmpty else { return nil }
        if !mentionsSum(trimmed, format: format), case .success(let value)? = evaluateTrailing(trimmed, format: format, sum: nil), !value.isPercent {
            return value
        }
        var scanner = Scanner(text: trimmed, format: format)
        var last: Value?
        while let value = scanner.nextAmount() { last = value }
        return last
    }

    private static func total(of block: [Value]) -> Value {
        var sum = 0.0
        var currencies = Set<String>()
        for value in block {
            sum += value.number
            if let currency = value.currency { currencies.insert(currency) }
        }
        return Value(sum, currency: currencies.count == 1 ? currencies.first : nil)
    }

    // MARK: - Evaluation

    /// The expression at the end of a line that starts with a label
    /// (`Hotel 3 * $95`, `split: $777 / 2`): the whole text when it is
    /// arithmetic, else the longest tail that is, starting after a space
    /// at a number, a currency, a sign, a paren or `sum` — provided what
    /// is skipped is words only. A malformed expression (`2 + (3 * 4`) is
    /// not a label and gets no answer from its valid tail.
    public static func evaluateTrailing(_ text: String, format: Format = .point, sum: Value? = nil) -> Result<Value, Failure>? {
        guard text.count <= inputLimit else { return nil }
        if let outcome = evaluate(text, format: format, sum: sum) { return outcome }
        let characters = Array(text)
        for (index, c) in characters.enumerated() where index > 0 {
            let before = characters[index - 1]
            guard before == " " || before == "\t" else { continue }
            let starts = (c.isASCII && c.isNumber) || currencySymbols.contains(c) || c == "(" || c == "." || c == "-"
                || (c == "s" && String(characters[index...].prefix(3)).lowercased() == "sum")
            guard starts, isLabel(characters[..<index]) else { continue }
            return evaluate(String(characters[index...]), format: format, sum: sum)
        }
        return nil
    }

    /// Words, spaces and a colon or comma: what may stand before an
    /// expression on its line. A digit, a currency or an operator is
    /// arithmetic that failed, not a label.
    private static func isLabel(_ prefix: ArraySlice<Character>) -> Bool {
        prefix.allSatisfy { $0.isLetter || $0 == " " || $0 == "\t" || $0 == ":" || $0 == "," || $0 == "'" || $0 == "’" || $0 == "." }
    }

    /// The value of one expression; nil when the text is not arithmetic
    /// (a word, an unbalanced paren, too long), `.failure` when it is but
    /// has no answer (÷0, overflow). `sum` is what the word stands for;
    /// without one, an expression that uses it is not arithmetic.
    public static func evaluate(_ expression: String, format: Format = .point, sum: Value? = nil) -> Result<Value, Failure>? {
        guard expression.count <= inputLimit, let tokens = tokens(in: expression, format: format), !tokens.isEmpty else { return nil }
        guard tokens.contains(where: { if case .number = $0 { true } else { $0 == .sum } }) else { return nil }
        var parser = Parser(tokens: tokens, sum: sum)
        return parser.run()
    }

    /// The answer as the editor draws it: grouped thousands, the format's
    /// decimal separator, two decimals for money (none when whole), up to
    /// four otherwise, `%` after a share; "÷0" and "overflow" for the
    /// failures.
    public static func display(_ outcome: Result<Value, Failure>, format: Format = .point) -> String {
        switch outcome {
        case .failure(.divisionByZero): return "÷0"
        case .failure(.overflow): return "overflow"
        case .success(let value): return display(value, format: format)
        }
    }

    public static func display(_ value: Value, format: Format = .point) -> String {
        if value.isPercent {
            let share = number(abs(value.number) * 100, fractionDigits: 2, format: format)
            return (value.number < 0 && share != "0" ? "-" : "") + share + "%"
        }
        let digits = value.currency != nil ? 2 : 4
        var text = number(abs(value.number), fractionDigits: digits, format: format, trimZeros: value.currency == nil)
        if let currency = value.currency { text = currency + text }
        // "-0" is nobody's answer.
        let negative = value.number < 0 && text != (value.currency ?? "") + "0"
        return negative ? "-" + text : text
    }

    private static func number(_ magnitude: Double, fractionDigits: Int, format: Format, trimZeros: Bool = true) -> String {
        let scale = pow(10, Double(fractionDigits))
        let rounded = (magnitude * scale).rounded() / scale
        var whole = rounded.rounded(.down)
        var fraction = ((rounded - whole) * scale).rounded()
        if fraction >= scale { whole += 1; fraction -= scale }
        var integerText = String(format: "%.0f", whole)
        if !format.groupingSeparator.isEmpty, integerText.count > 3 {
            var grouped = ""
            for (offset, character) in integerText.reversed().enumerated() {
                if offset > 0, offset.isMultiple(of: 3) { grouped.append(contentsOf: format.groupingSeparator.reversed()) }
                grouped.append(character)
            }
            integerText = String(grouped.reversed())
        }
        var fractionText = fraction == 0 ? "" : String(format: "%0\(fractionDigits).0f", fraction)
        while trimZeros, fractionText.hasSuffix("0") { fractionText.removeLast() }
        return fractionText.isEmpty ? integerText : integerText + format.decimalSeparator + fractionText
    }

    // MARK: - Tokens

    static let currencySymbols: Set<Character> = ["$", "€", "£"]

    enum Token: Hashable {
        case number(Value)
        case plus, minus, times, divide, power, remainder, of, open, close, percent, sum
    }

    /// The expression's tokens, or nil for anything that is not one.
    static func tokens(in expression: String, format: Format) -> [Token]? {
        var scanner = Scanner(text: expression, format: format)
        var tokens: [Token] = []
        while let token = scanner.next() {
            tokens.append(token)
            if tokens.count > inputLimit { return nil }
        }
        return scanner.failed ? nil : tokens
    }

    /// Reads characters into tokens.
    struct Scanner {
        private let characters: [Character]
        private var index = 0
        private let format: Format
        /// A character that is not arithmetic was met; the scan stopped.
        private(set) var failed = false

        init(text: String, format: Format) {
            characters = Array(text)
            self.format = format
        }

        private var current: Character? { index < characters.count ? characters[index] : nil }

        private mutating func skipSpaces() {
            while let c = current, c == " " || c == "\t" { index += 1 }
        }

        private func digits(from position: Int) -> Int {
            var count = 0
            var look = position
            while look < characters.count, characters[look].isASCII, characters[look].isNumber { count += 1; look += 1 }
            return count
        }

        /// The next token; nil at the end or at a character that is not
        /// one (then `failed`).
        mutating func next() -> Token? {
            skipSpaces()
            guard let c = current else { return nil }
            switch c {
            case "+": index += 1; return .plus
            case "-", "−", "–": index += 1; return .minus
            case "*", "×", "·": index += 1; return .times
            case "/", "÷": index += 1; return .divide
            case "^": index += 1; return .power
            case "(": index += 1; return .open
            case ")": index += 1; return .close
            case "%":
                index += 1
                // `10 % 3` is a remainder; `10%` then an operator or the end, a share.
                var look = index
                while look < characters.count, characters[look] == " " { look += 1 }
                if look < characters.count, characters[look].isNumber || characters[look] == "(" || Arithmetic.currencySymbols.contains(characters[look]) || characters[look] == "." {
                    return .remainder
                }
                return .percent
            default:
                break
            }
            if let word = word() {
                switch word {
                case "of": index += 2; return .of
                case "sum": index += 3; return .sum
                case "x": index += 1; return .times
                default: failed = true; return nil
                }
            }
            if let value = readAmount() { return .number(value) }
            failed = true
            return nil
        }

        /// Letters at the cursor, lowercased, not consumed.
        private func word() -> String? {
            var look = index
            var letters = ""
            while look < characters.count, characters[look].isLetter { letters.append(characters[look]); look += 1 }
            return letters.isEmpty ? nil : letters.lowercased()
        }

        /// A number with its currency (either side) and `k`/`M` suffix.
        private mutating func readAmount() -> Value? {
            let mark = index
            var currency: String?
            if let c = current, Arithmetic.currencySymbols.contains(c) {
                currency = String(c)
                index += 1
                skipSpaces()
            }
            guard var value = readNumber() else { index = mark; return nil }
            if let c = current, c == "k" || c == "K" || c == "M", !(index + 1 < characters.count && characters[index + 1].isLetter) {
                value *= c == "M" ? 1_000_000 : 1_000
                index += 1
            }
            if currency == nil {
                var look = index
                while look < characters.count, characters[look] == " " { look += 1 }
                if look < characters.count, Arithmetic.currencySymbols.contains(characters[look]) {
                    currency = String(characters[look])
                    index = look + 1
                }
            }
            // A number glued to a word or a time (`3rd`, `10:30`) is not an amount.
            if let c = current, c.isLetter || c == ":" { index = mark; return nil }
            return Value(value, currency: currency)
        }

        /// Digits with the format's grouping and decimal separators. A
        /// grouping separator must be followed by exactly three digits;
        /// a `.` that is not, in a comma format, still reads as a decimal
        /// point when no decimal has been seen.
        private mutating func readNumber() -> Double? {
            var text = ""
            var sawDigit = false
            var sawDecimal = false
            let start = index
            while let c = current {
                let s = String(c)
                if c.isASCII, c.isNumber {
                    text.append(c)
                    sawDigit = true
                    index += 1
                } else if s == format.decimalSeparator, !sawDecimal, digits(from: index + 1) > 0 {
                    text.append(".")
                    sawDecimal = true
                    index += 1
                } else if s == format.groupingSeparator, sawDigit, !sawDecimal, digits(from: index + 1) == 3,
                          !(index + 4 < characters.count && String(characters[index + 4]) == format.groupingSeparator && digits(from: index + 5) != 3) {
                    index += 1
                } else if c == ".", !sawDecimal, format.decimalSeparator != ".", digits(from: index + 1) > 0, digits(from: index + 1) != 3 {
                    text.append(".")
                    sawDecimal = true
                    index += 1
                } else {
                    break
                }
            }
            guard sawDigit else { index = start; return nil }
            if text.hasPrefix(".") { text = "0" + text }
            return Double(text)
        }

        /// For the amounts above a `sum`: the next number in the text that
        /// stands on its own, skipping words and punctuation; nil at the end.
        mutating func nextAmount() -> Value? {
            while index < characters.count {
                skipSpaces()
                guard let c = current else { return nil }
                let startsAmount = (c.isASCII && c.isNumber) || Arithmetic.currencySymbols.contains(c) || (c == "." && digits(from: index + 1) > 0)
                if startsAmount {
                    let before = index > 0 ? characters[index - 1] : " "
                    let standalone = before == " " || before == "\t" || before == "(" || before == "-" || before == "+" || before == "="
                    let mark = index
                    if standalone, let value = readAmount() { return value }
                    index = max(mark + 1, index)
                    // The rest of a token that is not an amount (`10:30`, `3rd`).
                    while let d = current, d.isNumber || d.isLetter || d == ":" || d == "." || d == "," { index += 1 }
                } else {
                    index += 1
                }
            }
            return nil
        }
    }

    // MARK: - Parser

    /// Recursive descent over the tokens: sums, then products (with `of`
    /// and remainders), then signs, then powers (right-associative, above
    /// the sign: `-2^2` is `-4`), then a postfix `%`, then numbers and
    /// parentheses. Depth is bounded.
    struct Parser {
        private let tokens: [Token]
        private var index = 0
        private var depth = 0
        private let sum: Value?

        init(tokens: [Token], sum: Value?) {
            self.tokens = tokens
            self.sum = sum
        }

        private var current: Token? { index < tokens.count ? tokens[index] : nil }

        private struct NotArithmetic: Error {}

        /// nil when the tokens are not an expression.
        mutating func run() -> Result<Value, Failure>? {
            do {
                let value = try expression()
                guard current == nil else { return nil }
                return .success(try checked(value))
            } catch let failure as Failure {
                return .failure(failure)
            } catch {
                return nil
            }
        }

        private func checked(_ value: Value) throws -> Value {
            guard value.number.isFinite, abs(value.number) < Arithmetic.magnitudeLimit else { throw Failure.overflow }
            return value
        }

        private mutating func expression() throws -> Value {
            var left = try product()
            while let token = current, token == .plus || token == .minus {
                index += 1
                let right = try product()
                let sign: Double = token == .plus ? 1 : -1
                if right.isPercent, !left.isPercent {
                    // `80 + 10%`: a tenth more.
                    left = Value(left.number * (1 + sign * right.number), currency: left.currency)
                } else if left.isPercent, right.isPercent {
                    left = Value(left.number + sign * right.number, isPercent: true)
                } else {
                    left = Value(left.number + sign * right.number, currency: Arithmetic.carried(left, right, sum: true))
                }
                left = try checked(left)
            }
            return left
        }

        private mutating func product() throws -> Value {
            var left = try unary()
            while let token = current, token == .times || token == .divide || token == .of || token == .remainder {
                index += 1
                let right = try unary()
                switch token {
                case .divide:
                    guard right.number != 0 else { throw Failure.divisionByZero }
                    left = Value(left.number / right.number, currency: right.currency == nil ? left.currency : nil)
                case .remainder:
                    guard right.number != 0 else { throw Failure.divisionByZero }
                    left = Value(left.number.truncatingRemainder(dividingBy: right.number), currency: left.currency)
                default:
                    left = Value(left.number * right.number, currency: Arithmetic.carried(left, right, sum: false))
                }
                left = try checked(left)
            }
            return left
        }

        private mutating func unary() throws -> Value {
            if current == .minus {
                index += 1
                var value = try unary()
                value.number = -value.number
                return value
            }
            if current == .plus {
                index += 1
                return try unary()
            }
            return try power()
        }

        private mutating func power() throws -> Value {
            let base = try postfix()
            guard current == .power else { return base }
            index += 1
            let exponent = try unary()
            guard !exponent.isPercent, exponent.currency == nil, !base.isPercent else { throw NotArithmetic() }
            return try checked(Value(pow(base.number, exponent.number), currency: base.currency))
        }

        private mutating func postfix() throws -> Value {
            let value = try primary()
            guard current == .percent else { return value }
            index += 1
            guard value.currency == nil, !value.isPercent else { throw NotArithmetic() }
            return Value(value.number / 100, isPercent: true)
        }

        private mutating func primary() throws -> Value {
            guard let token = current else { throw NotArithmetic() }
            switch token {
            case .number(let value):
                index += 1
                return value
            case .sum:
                index += 1
                guard let sum else { throw NotArithmetic() }
                return sum
            case .open:
                depth += 1
                guard depth <= Arithmetic.depthLimit else { throw NotArithmetic() }
                index += 1
                let inner = try expression()
                guard current == .close else { throw NotArithmetic() }
                index += 1
                depth -= 1
                return inner
            default:
                throw NotArithmetic()
            }
        }
    }

    /// The currency an operation carries: the one both sides agree on,
    /// or the one side that has one; for a product, at most one side may
    /// carry it (money times money is nobody's unit).
    private static func carried(_ left: Value, _ right: Value, sum: Bool) -> String? {
        switch (left.currency, right.currency) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?): return sum && l == r ? l : nil
        }
    }
}
