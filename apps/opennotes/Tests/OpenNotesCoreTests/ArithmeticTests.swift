import XCTest
@testable import OpenNotesCore

/// A tiny seeded generator, for the fuzz test: same inputs every run.
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }
}

/// `Arithmetic.evaluate`/`display`/`answers`: precedence, unary and power,
/// division and overflow, thousands and `k`/`M`, currency carry, percent,
/// decimals, both number formats, bounds, and the `=` line rules.
final class ArithmeticTests: XCTestCase {
    private func value(_ expression: String, format: Arithmetic.Format = .point, sum: Arithmetic.Value? = nil) -> String? {
        guard let outcome = Arithmetic.evaluate(expression, format: format, sum: sum) else { return nil }
        return Arithmetic.display(outcome, format: format)
    }

    // MARK: - Precedence, unary, power

    @MainActor func testPrecedence() {
        XCTAssertEqual(value("2 + 3 * 4"), "14")
        XCTAssertEqual(value("(1 + 2) * (3 + 4)"), "21")
    }

    @MainActor func testUnaryMinus() {
        XCTAssertEqual(value("-2^2"), "-4")
        XCTAssertEqual(value("2 - -3"), "5")
        XCTAssertEqual(value("2 ^ -1"), "0.5")
    }

    @MainActor func testPowerIsRightAssociative() {
        XCTAssertEqual(value("2^3^2"), "512")
    }

    // MARK: - Division and overflow

    @MainActor func testDivisionByZero() {
        XCTAssertEqual(value("10 / 0"), "÷0")
        XCTAssertEqual(value("10 % 0"), "÷0")
    }

    @MainActor func testOverflow() {
        XCTAssertEqual(value("2 ^ 1000"), "overflow")
        XCTAssertEqual(value("999999999999999 * 10"), "overflow")
    }

    // MARK: - Thousands, k/M

    @MainActor func testThousandsSeparator() {
        XCTAssertEqual(value("1,000 + 500"), "1,500")
        XCTAssertNil(value("1,00,000"))
    }

    @MainActor func testKAndM() {
        XCTAssertEqual(value("2k * 3"), "6,000")
        XCTAssertEqual(value("1.5M / 2"), "750,000")
        XCTAssertNil(value("2km"))
    }

    // MARK: - Currency carry

    @MainActor func testCurrencyCarry() {
        XCTAssertEqual(value("$12 + $8.50"), "$20.50")
        XCTAssertEqual(value("$12 * 2"), "$24")
        XCTAssertEqual(value("$12 / $4"), "3")
        XCTAssertEqual(value("£3 + €4"), "7")
        XCTAssertEqual(value("12% of $80"), "$9.60")
        XCTAssertEqual(value("$80 * 12%"), "$9.60")
    }

    // MARK: - Percent

    @MainActor func testPercent() {
        XCTAssertEqual(value("12% of 80"), "9.6")
        XCTAssertEqual(value("80 + 10%"), "88")
        XCTAssertEqual(value("80 - 10%"), "72")
        XCTAssertEqual(value("10%"), "10%")
        XCTAssertEqual(value("10 % 3"), "1")
    }

    // MARK: - Decimals

    @MainActor func testDecimals() {
        XCTAssertEqual(value("10 / 3"), "3.3333")
        XCTAssertEqual(value(".5 + .25"), "0.75")
    }

    // MARK: - Comma format

    @MainActor func testCommaFormat() {
        XCTAssertEqual(value("1,5 + 1", format: .comma), "2,5")
        XCTAssertEqual(value("1.000,50 + 0,5", format: .comma), "1.001")
        XCTAssertEqual(value("2,5 * 2", format: .comma), "5")
        XCTAssertEqual(Arithmetic.display(Arithmetic.Value(1500.5), format: .comma), "1.500,5")
    }

    @MainActor func testFormatFromLocale() {
        XCTAssertEqual(Arithmetic.Format(locale: Locale(identifier: "de_DE")), .comma)
        XCTAssertEqual(Arithmetic.Format(locale: Locale(identifier: "en_US")), .point)
        XCTAssertTrue(Arithmetic.Format(locale: Locale(identifier: "fr_FR")).groupingSeparator.isEmpty)
    }

    // MARK: - Not arithmetic

    @MainActor func testNotArithmeticIsNil() {
        for text in ["hello", "1 +", "2 * (3", "1.2.3", "1e5", "x", ""] {
            XCTAssertNil(Arithmetic.evaluate(text), text)
        }
        XCTAssertNil(Arithmetic.evaluate("sum"), "sum without a sum value")
    }

    @MainActor func testSumSubstitution() {
        XCTAssertEqual(value("sum + 1", sum: Arithmetic.Value(5)), "6")
    }

    // MARK: - evaluateTrailing

    @MainActor func testEvaluateTrailing() {
        func trailing(_ text: String) -> String? {
            guard let outcome = Arithmetic.evaluateTrailing(text) else { return nil }
            return Arithmetic.display(outcome)
        }
        XCTAssertEqual(trailing("Hotel 3 * $95"), "$285")
        XCTAssertEqual(trailing("split: $777 / 2"), "$388.50")
        XCTAssertNil(trailing("Meeting at 10:30"))
    }

    // MARK: - Bounds

    @MainActor func testInputTooLongIsNil() {
        let expression = String(repeating: "1", count: 201)
        XCTAssertEqual(expression.count, 201)
        XCTAssertNil(Arithmetic.evaluate(expression))
    }

    @MainActor func testNestingPastTheDepthLimitIsNil() {
        let tooDeep = String(repeating: "(", count: 33) + "1" + String(repeating: ")", count: 33)
        XCTAssertNil(Arithmetic.evaluate(tooDeep))
    }

    @MainActor func testNestingAtTheDepthLimitIsAValue() {
        let atLimit = String(repeating: "(", count: 32) + "1" + String(repeating: ")", count: 32)
        XCTAssertNotNil(Arithmetic.evaluate(atLimit))
    }

    // MARK: - answers(in:)

    @MainActor func testAnEqualsLineWithNoOldAnswerIsInsertedAfterTheEquals() {
        let text = "3 * $95 ="
        let answers = Arithmetic.answers(in: text)
        let answer = try! XCTUnwrap(answers.first)
        XCTAssertNil(answer.oldAnswerRange)
        XCTAssertTrue(answer.needsDrawing)
        XCTAssertEqual(answer.text, "$285")
        let commit = answer.commit
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: commit.range, with: commit.replacement)
        XCTAssertEqual(ns as String, "3 * $95 = $285")
    }

    @MainActor func testACurrentOldAnswerIsNotRedrawn() {
        let text = "2 + 2 = 4"
        let answer = try! XCTUnwrap(Arithmetic.answers(in: text).first)
        XCTAssertTrue(answer.isCurrent)
        XCTAssertFalse(answer.needsDrawing)
        let commit = answer.commit
        XCTAssertEqual(commit.replacement, "4")
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: commit.range, with: commit.replacement)
        XCTAssertEqual(ns as String, "2 + 2 = 4")
    }

    @MainActor func testAStaleOldAnswerIsMarkedAndReplaced() {
        let text = "3 * 3 = 4"
        let answer = try! XCTUnwrap(Arithmetic.answers(in: text).first)
        XCTAssertTrue(answer.isStale)
        XCTAssertTrue(answer.needsDrawing)
        let ns = text as NSString
        XCTAssertEqual(answer.commit.range, ns.range(of: "4", options: .backwards))
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: answer.commit.range, with: answer.commit.replacement)
        XCTAssertEqual(mutable as String, "3 * 3 = 9")
    }

    @MainActor func testSumOverTheBlockAboveUntilABlankLine() {
        let text = "Lunch $12\n- [x] taxi 8.50\nMeeting at 10:30\nsum ="
        let answers = Arithmetic.answers(in: text)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.text, "$20.50")
    }

    @MainActor func testABlankLineEndsTheBlock() {
        let text = "Lunch $12\n\nsum ="
        let answers = Arithmetic.answers(in: text)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.text, "0")
    }

    @MainActor func testComparisonAndAssignmentOperatorsAreNotAnswers() {
        for line in ["x == y", "a <= b", "a := b", "a >= b", "a != b"] {
            XCTAssertTrue(Arithmetic.answers(in: line).isEmpty, line)
        }
    }

    @MainActor func testAnEqualsInsideBackticksIsIgnored() {
        XCTAssertTrue(Arithmetic.answers(in: "`2 + 2 =`").isEmpty)
    }

    @MainActor func testAHeadingLineIsAnswered() {
        let answers = Arithmetic.answers(in: "# 2^10 =")
        XCTAssertEqual(answers.first?.text, "1,024")
    }

    @MainActor func testAListLineIsAnswered() {
        let answers = Arithmetic.answers(in: "- 2 * 3 =")
        XCTAssertEqual(answers.first?.text, "6")
    }

    @MainActor func testANonArithmeticLabelHasNoAnswer() {
        XCTAssertTrue(Arithmetic.answers(in: "x = 5").isEmpty)
    }

    @MainActor func testAnswerAtCaretFindsTheLineIncludingItsEnd() {
        let text = "Title\n2 + 2 =\nmore text"
        let lineRange = (text as NSString).range(of: "2 + 2 =")
        XCTAssertNotNil(Arithmetic.answer(in: text, at: lineRange.location))
        XCTAssertNotNil(Arithmetic.answer(in: text, at: lineRange.location + 3))
        XCTAssertNotNil(Arithmetic.answer(in: text, at: NSMaxRange(lineRange)))
        XCTAssertNil(Arithmetic.answer(in: text, at: 0))
    }

    // MARK: - Fuzz

    @MainActor func testFuzzNeverCrashesAndRangesStayInBounds() {
        let alphabet = Array("0123456789+-*/^()%$€£kM.,= sumofx\t🙂é日")
        var rng = LCG(state: 42)
        let start = Date()
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...60, using: &rng)
            var text = ""
            text.reserveCapacity(length)
            for _ in 0..<length {
                text.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
            }
            let ns = text as NSString
            _ = Arithmetic.evaluate(text)
            _ = Arithmetic.evaluateTrailing(text)
            let answers = Arithmetic.answers(in: text)
            for answer in answers {
                XCTAssertTrue(answer.lineRange.location >= 0 && NSMaxRange(answer.lineRange) <= ns.length, text)
                if let old = answer.oldAnswerRange {
                    XCTAssertTrue(old.location >= 0 && NSMaxRange(old) <= ns.length, text)
                }
            }
            if let outcome = Arithmetic.evaluate(text) {
                _ = Arithmetic.display(outcome)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 30, "fuzz loop should run in a generous time")
    }

    @MainActor func testAnswersRunsUnderAGenerousTimeOnALongLine() {
        let text = String(repeating: "1+", count: 99) + "1" + " ="
        XCTAssertLessThanOrEqual(text.count, 400)
        let start = Date()
        _ = Arithmetic.answers(in: text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    @MainActor func testPathologicalStringsDoNotCrash() {
        let strings = [
            String(repeating: "(", count: 200),
            String(repeating: "-", count: 200),
            "1e308 * 1e308",
            String(repeating: "9", count: 200),
            "$$$",
            "%%%",
            ",,,",
            "...",
            "= = =",
        ]
        for text in strings {
            _ = Arithmetic.evaluate(text)
            _ = Arithmetic.evaluateTrailing(text)
            _ = Arithmetic.answers(in: text)
            if let outcome = Arithmetic.evaluate(text) {
                _ = Arithmetic.display(outcome)
            }
        }
    }

    // MARK: - A label before the expression, and nothing else

    @MainActor func testAMalformedExpressionNeverAnswersFromItsValidTail() {
        XCTAssertNil(Arithmetic.evaluateTrailing("2 + (3 * 4"), "an unbalanced paren is not a label")
        XCTAssertNil(Arithmetic.evaluateTrailing("2 * (3 * 4"))
        XCTAssertNil(Arithmetic.evaluateTrailing("2 ** 3 * 4"))
        XCTAssertNil(Arithmetic.evaluateTrailing("2 +) 3 * 4"))
        XCTAssertNil(Arithmetic.evaluateTrailing("(2 3 * 4"))
        XCTAssertEqual(Arithmetic.answers(in: "2 + (3 * 4 ="), [])
        XCTAssertEqual(Arithmetic.answers(in: "x: 2 + (3 * 4 ="), [])
    }

    @MainActor func testOnlyWordsMayStandBeforeTheExpression() {
        XCTAssertEqual(Arithmetic.evaluateTrailing("Hotel 3 * $95").map { Arithmetic.display($0) }, "$285")
        XCTAssertEqual(Arithmetic.evaluateTrailing("split: $777 / 2").map { Arithmetic.display($0) }, "$388.50")
        XCTAssertEqual(Arithmetic.evaluateTrailing("Bob's lunch, tip incl. $12 + $3").map { Arithmetic.display($0) }, "$15")
        XCTAssertEqual(Arithmetic.evaluateTrailing("total sum * 2", sum: Arithmetic.Value(5)).map { Arithmetic.display($0) }, "10")
        XCTAssertNil(Arithmetic.evaluateTrailing("3 coffees at 4.50"), "a digit in the prefix is arithmetic that failed")
    }

    @MainActor func testSumTimesACommaNumberFollowsTheFormat() {
        // In the point format `1,5` is neither a decimal nor a thousands group: no answer.
        XCTAssertNil(Arithmetic.evaluate("sum * 1,5", format: .point, sum: Arithmetic.Value(4)))
        XCTAssertNil(Arithmetic.evaluateTrailing("sum * 1,5", format: .point, sum: Arithmetic.Value(4)))
        XCTAssertEqual(Arithmetic.answers(in: "2\n2\nsum * 1,5 =", format: .point), [])
        // In the comma format it is one and a half.
        XCTAssertEqual(value("sum * 1,5", format: .comma, sum: Arithmetic.Value(4)), "6")
        XCTAssertEqual(Arithmetic.answers(in: "2\n2\nsum * 1,5 =", format: .comma).map(\.text), ["6"])
        // And `1,500` groups in the point format, is a decimal in the comma one.
        XCTAssertEqual(value("sum + 1,500", format: .point, sum: Arithmetic.Value(1)), "1,501")
        XCTAssertEqual(value("sum + 1,500", format: .comma, sum: Arithmetic.Value(1)), "2,5")
    }
}
