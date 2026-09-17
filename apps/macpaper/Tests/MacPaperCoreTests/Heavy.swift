import Foundation
import Testing

extension Tag {
    /// A test that takes minutes on a CI runner: rendering at 4K or more,
    /// every preset through every context, a budget measured in wall-clock
    /// time. Marked `.heavy` (below) as well, which is what actually gates it.
    @Tag static var heavy: Self
}

extension Trait where Self == ConditionTrait {
    /// Runs the test unless `OPENAPPS_HEAVY_TESTS=0`, which the checks that
    /// gate every push set; the nightly run and a local `swift test` leave
    /// it unset and run everything (RELEASES.md, "Pipeline"). A heavy test
    /// carries `.tags(.heavy)` too, so Xcode's filters see it.
    static var heavy: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["OPENAPPS_HEAVY_TESTS"] != "0",
            "Heavy tests are off (OPENAPPS_HEAVY_TESTS=0): the nightly run and a local swift test run them"
        )
    }
}
