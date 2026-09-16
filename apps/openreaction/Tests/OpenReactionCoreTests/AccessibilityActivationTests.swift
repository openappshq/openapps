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

    /// Drives the decision the way `FocusMonitor` does: on each activation, ask
    /// whether to enable and, if so, call the seam.
    private func activate(_ activation: inout AccessibilityActivation, _ enabler: FakeEnabler, pid: Int32, excluded: Bool) {
        if activation.shouldEnable(pid: pid, excluded: excluded) { enabler.enableTree(pid: pid) }
    }

    @Test func enablesOncePerPidAndNeverForExcludedApps() {
        var activation = AccessibilityActivation()
        let enabler = FakeEnabler()
        activate(&activation, enabler, pid: 10, excluded: false)
        activate(&activation, enabler, pid: 10, excluded: false) // once per pid
        activate(&activation, enabler, pid: 20, excluded: true)  // excluded → none
        activate(&activation, enabler, pid: 30, excluded: false)
        #expect(enabler.enabled == [10, 30])
    }

    @Test func anAppUnExcludedLaterEnablesOnItsNextActivation() {
        var activation = AccessibilityActivation()
        let enabler = FakeEnabler()
        activate(&activation, enabler, pid: 42, excluded: true)  // excluded: nothing
        #expect(enabler.enabled.isEmpty)
        activate(&activation, enabler, pid: 42, excluded: false) // now allowed, first sight
        #expect(enabler.enabled == [42])
    }
}
