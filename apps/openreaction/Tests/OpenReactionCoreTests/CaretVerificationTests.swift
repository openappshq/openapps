import OpenReactionCore
import Testing

@Suite("Caret verification")
struct CaretVerificationTests {
    // MARK: - Named sanity cases

    private func decide(
        role: AXStringAnswer = .value("AXTextField"),
        subrole: AXStringAnswer = .absent,
        typed: String = ":tada",
        selection: (location: Int, length: Int)?,
        text: @escaping (Int, Int) -> String? = { _, _ in nil }
    ) -> VerifyDecision {
        CaretVerification.decide(
            role: role, subrole: subrole, typedCount: typed.utf16.count,
            selection: selection, typed: typed, textBeforeCaret: text
        )
    }

    @Test func aPositivelySecureSubroleRefusesEvenIfTextMatches() {
        let decision = decide(subrole: .value("AXSecureTextField"), selection: (5, 0)) { _, _ in ":tada" }
        #expect(decision == .refused)
    }

    @Test func anUnreadableSubroleRefusesEvenWhenTextMatches() {
        // The verified path must not post into a field whose secure status could
        // not be confirmed, even though the text reads back equal to the token.
        let decision = decide(role: .value("AXTextField"), subrole: .unreadable, selection: (5, 0)) { _, _ in ":tada" }
        #expect(decision == .refused)
    }

    @Test func theVerifiedPathIsRoleIndependentWithAnAcceptableSubrole() {
        // Any role is fine once the subrole is positively non-secure (here
        // genuinely absent) and the text reads back equal to the token.
        for role in [AXStringAnswer.value("AXButton"), .absent, .unreadable] {
            #expect(decide(role: role, subrole: .absent, selection: (5, 0)) { _, _ in ":tada" } == .keystrokes)
        }
    }

    @Test func isSecureMapsEveryAnswerState() {
        #expect(CaretVerification.isSecure(subrole: .value("AXSecureTextField")) == true)
        #expect(CaretVerification.isSecure(subrole: .value("AXTextField")) == false)
        #expect(CaretVerification.isSecure(subrole: .absent) == false)
        #expect(CaretVerification.isSecure(subrole: .unreadable) == nil) // fail-closed
    }

    // MARK: - Full Cartesian matrix

    private final class ReadRecorder {
        private(set) var ranges: [(location: Int, length: Int)] = []
        private let answer: (Int, Int) -> String?
        init(_ answer: @escaping (Int, Int) -> String?) { self.answer = answer }
        func read(_ location: Int, _ length: Int) -> String? {
            ranges.append((location, length))
            return answer(location, length)
        }
    }

    private enum Component { case candidate, matching, mismatch }

    private struct Scenario {
        let name: String
        let selection: (location: Int, length: Int)?
        let answer: (Int, Int) -> String?
        let component: Component
        /// The range `decide` should read from the field, or nil for no read.
        let expectedRead: (location: Int, length: Int)?
    }

    /// The complete matrix (review 2), fixed so an unreadable subrole refuses
    /// every posting outcome. Each entry is (candidate, matching, mismatch);
    /// `R`efused / `V`erified keystrokes / `F`allback unverifiable.
    private typealias Triple = (candidate: VerifyDecision, matching: VerifyDecision, mismatch: VerifyDecision)

    private enum RoleGroup: CaseIterable {
        case textRole, otherValue, absent, unreadable
        var answers: [AXStringAnswer] {
            switch self {
            case .textRole: [.value("AXTextField"), .value("AXTextArea"), .value("AXComboBox"), .value("AXSearchField")]
            case .otherValue: [.value("AXButton"), .value("")]
            case .absent: [.absent]
            case .unreadable: [.unreadable]
            }
        }
    }

    private enum SubroleColumn: CaseIterable {
        case secure, nonSecure, absent, unreadable
        var answers: [AXStringAnswer] {
            switch self {
            case .secure: [.value("AXSecureTextField")]
            case .nonSecure: [.value("AXInlineTextField"), .value("")] // empty string is non-secure
            case .absent: [.absent]
            case .unreadable: [.unreadable]
            }
        }
    }

    private func triple(_ role: RoleGroup, _ subrole: SubroleColumn) -> Triple {
        let R = VerifyDecision.refused, V = VerifyDecision.keystrokes, F = VerifyDecision.unverifiable
        switch subrole {
        case .secure, .unreadable:
            return (R, R, R) // subrole not positively non-secure: nothing posts
        case .nonSecure, .absent:
            // Matching text verifies for any role; mismatch refuses; a candidate
            // falls back only for a positively text role.
            return role == .textRole ? (F, V, R) : (R, V, R)
        }
    }

    private var scenarios: [Scenario] {
        [
            Scenario(name: "unreadable selection", selection: nil, answer: { _, _ in nil },
                     component: .candidate, expectedRead: nil),
            Scenario(name: "{0,0} unreadable before-text", selection: (0, 0), answer: { _, _ in nil },
                     component: .candidate, expectedRead: (0, 0)),
            Scenario(name: "{0,0} readable-empty before-text", selection: (0, 0),
                     answer: { location, length in location == 0 && length == 0 ? "" : "unexpected" },
                     component: .candidate, expectedRead: (0, 0)),
            Scenario(name: "location >= N, unreadable before-text", selection: (5, 0), answer: { _, _ in nil },
                     component: .candidate, expectedRead: (0, 5)),
            Scenario(name: "location >= N, matching before-text", selection: (5, 0),
                     answer: { location, length in location == 0 && length == 5 ? ":tada" : "unexpected" },
                     component: .matching, expectedRead: (0, 5)),
            Scenario(name: "real selection", selection: (5, 3), answer: { _, _ in nil },
                     component: .mismatch, expectedRead: nil),
            Scenario(name: "0 < location < N", selection: (2, 0), answer: { _, _ in nil },
                     component: .mismatch, expectedRead: nil),
            Scenario(name: "{0,0} readable-nonempty before-text", selection: (0, 0), answer: { _, _ in "x" },
                     component: .mismatch, expectedRead: (0, 0)),
            Scenario(name: "location >= N, differing before-text", selection: (5, 0), answer: { _, _ in "hello" },
                     component: .mismatch, expectedRead: (0, 5)),
        ]
    }

    @Test func everyMatrixCellDecidesAsExpectedAndReadsTheRightRange() {
        for roleGroup in RoleGroup.allCases {
            for subroleColumn in SubroleColumn.allCases {
                let expected = triple(roleGroup, subroleColumn)
                for role in roleGroup.answers {
                    for subrole in subroleColumn.answers {
                        for scenario in scenarios {
                            let recorder = ReadRecorder(scenario.answer)
                            let decision = CaretVerification.decide(
                                role: role, subrole: subrole, typedCount: 5,
                                selection: scenario.selection, typed: ":tada",
                                textBeforeCaret: { recorder.read($0, $1) }
                            )
                            let want: VerifyDecision = switch scenario.component {
                            case .candidate: expected.candidate
                            case .matching: expected.matching
                            case .mismatch: expected.mismatch
                            }
                            let label = "\(roleGroup)/\(subroleColumn) role=\(role) subrole=\(subrole) — \(scenario.name)"
                            #expect(decision == want, "\(label): got \(decision), want \(want)")

                            // A secure or unreadable subrole short-circuits before
                            // any read; otherwise the scenario's range is read once.
                            let subrolePasses = CaretVerification.isSecure(subrole: subrole) == false
                            let performed = subrolePasses ? scenario.expectedRead : nil
                            if let performed {
                                #expect(recorder.ranges.count == 1, "\(label): expected one read")
                                #expect(
                                    recorder.ranges.first.map { $0 == performed } ?? false,
                                    "\(label): read \(String(describing: recorder.ranges.first)), want \(performed)"
                                )
                            } else {
                                #expect(recorder.ranges.isEmpty, "\(label): expected no read, got \(recorder.ranges)")
                            }
                        }
                    }
                }
            }
        }
    }
}
