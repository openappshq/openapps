import OpenReactionCore
import Testing

@Suite("Accessibility activation")
struct AccessibilityActivationTests {
    /// Records which pids the tree was enabled for, standing in for the live
    /// Accessibility writes.
    final class FakeEnabler: AccessibilityTreeEnabling, @unchecked Sendable {
        private(set) var enabled: [Int32] = []
        func enableTree(pid: Int32) { enabled.append(pid) }
    }

    /// Drives the decision the way `FocusMonitor`'s worker does: at execution,
    /// ask whether to enable (with the freshness of the activation that queued
    /// it) and, if so, call the seam.
    private func activate(
        _ activation: inout AccessibilityActivation, _ enabler: FakeEnabler,
        pid: Int32, excluded: Bool = false, fresh: Bool = true
    ) {
        if activation.shouldEnable(pid: pid, excluded: excluded, fresh: fresh) { enabler.enableTree(pid: pid) }
    }

    @Test func enablesOncePerPidAndNeverForExcludedApps() {
        var activation = AccessibilityActivation()
        let enabler = FakeEnabler()
        activate(&activation, enabler, pid: 10)
        activate(&activation, enabler, pid: 10) // once per pid
        activate(&activation, enabler, pid: 20, excluded: true) // excluded → none
        activate(&activation, enabler, pid: 30)
        #expect(enabler.enabled == [10, 30])
    }

    @Test func anAppUnExcludedLaterEnablesOnItsNextActivation() {
        var activation = AccessibilityActivation()
        let enabler = FakeEnabler()
        activate(&activation, enabler, pid: 42, excluded: true) // excluded: nothing
        #expect(enabler.enabled.isEmpty)
        activate(&activation, enabler, pid: 42) // now allowed, first sight
        #expect(enabler.enabled == [42])
    }

    @Test func aStaleWorkerJobWritesNothingAndDoesNotConsumeThePid() {
        // A queued enable that ran after focus moved (fresh == false) must write
        // nothing — and must not mark the pid, so the next current activation of
        // the same app still enables it.
        var activation = AccessibilityActivation()
        let enabler = FakeEnabler()
        activate(&activation, enabler, pid: 7, fresh: false)
        #expect(enabler.enabled.isEmpty)
        activate(&activation, enabler, pid: 7, fresh: true)
        #expect(enabler.enabled == [7])
    }
}
