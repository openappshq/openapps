import CoreGraphics
import Foundation
import OpenReactionCore
import Testing

private final class FakeProvider: PermissionProvider {
    var granted: Set<PermissionKind> = []
    func isGranted(_ kind: PermissionKind) -> Bool { granted.contains(kind) }
}

private final class ManualClock: FlowClock {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@Suite("Permission flow")
struct PermissionFlowTests {
    private let provider = FakeProvider()
    private let clock = ManualClock()

    private func makeFlow(identity: String = "build-1", memory: PermissionFlow.Memory = .init()) -> PermissionFlow {
        PermissionFlow(provider: provider, clock: clock, codeIdentity: identity, memory: memory)
    }

    private func grantAll(_ flow: inout PermissionFlow) {
        provider.granted = Set(PermissionKind.allCases)
        flow.refresh()
    }

    // MARK: Basic transitions

    @Test func startsMissing() {
        let flow = makeFlow()
        #expect(flow.status(of: .accessibility) == .missing)
        #expect(flow.status(of: .inputMonitoring) == .missing)
        #expect(!flow.isComplete)
    }

    @Test func requestThenGrant() {
        var flow = makeFlow()
        flow.didRequest(.accessibility)
        #expect(flow.status(of: .accessibility) == .requested)
        #expect(flow.status(of: .inputMonitoring) == .missing)

        provider.granted = [.accessibility]
        let changed = flow.refresh()
        #expect(changed)
        #expect(flow.status(of: .accessibility) == .granted)
        let changedAgain = flow.refresh()
        #expect(!changedAgain, "no change on an identical read")
    }

    @Test func requestingAnAlreadyGrantedPermissionStaysGranted() {
        provider.granted = [.inputMonitoring]
        var flow = makeFlow()
        flow.didRequest(.inputMonitoring)
        #expect(flow.status(of: .inputMonitoring) == .granted)
    }

    @Test func completeWhenBothGranted() {
        var flow = makeFlow()
        grantAll(&flow)
        #expect(flow.isComplete)
        #expect(flow.memory.grantedIdentity == [.accessibility: "build-1", .inputMonitoring: "build-1"])
    }

    @Test func revokedOnSameBuildIsMissingNotStale() {
        var flow = makeFlow()
        grantAll(&flow)
        provider.granted = [.inputMonitoring]
        flow.refresh()
        #expect(flow.status(of: .accessibility) == .missing)
        #expect(flow.memory.grantedIdentity[.accessibility] == nil)
    }

    @Test func requestIsForgottenOnceGranted() {
        var flow = makeFlow()
        flow.didRequest(.accessibility)
        provider.granted = [.accessibility]
        flow.refresh()
        provider.granted = []
        flow.refresh()
        #expect(flow.status(of: .accessibility) == .missing)
    }

    // MARK: Stale after update

    @Test func grantFromEarlierBuildNotHonoredIsStale() {
        let memory = PermissionFlow.Memory(grantedIdentity: [.accessibility: "build-1", .inputMonitoring: "build-1"])
        provider.granted = [.inputMonitoring]
        var flow = makeFlow(identity: "build-2", memory: memory)
        #expect(flow.status(of: .accessibility) == .stale)
        #expect(flow.status(of: .inputMonitoring) == .granted)
        #expect(flow.memory.grantedIdentity[.inputMonitoring] == "build-2")

        // Stale wins over requested: the switch is probably already on.
        flow.didRequest(.accessibility)
        #expect(flow.status(of: .accessibility) == .stale)
    }

    @Test func grantFromEarlierBuildStillHonoredIsGranted() {
        let memory = PermissionFlow.Memory(grantedIdentity: [.accessibility: "build-1"])
        provider.granted = [.accessibility]
        let flow = makeFlow(identity: "build-2", memory: memory)
        #expect(flow.status(of: .accessibility) == .granted)
        #expect(flow.memory.grantedIdentity[.accessibility] == "build-2")
    }

    @Test func resetClearsStale() {
        let memory = PermissionFlow.Memory(grantedIdentity: [.accessibility: "old"])
        var flow = makeFlow(identity: "new", memory: memory)
        #expect(flow.status(of: .accessibility) == .stale)
        flow.didReset(.accessibility)
        #expect(flow.status(of: .accessibility) == .missing)
        flow.didRequest(.accessibility)
        #expect(flow.status(of: .accessibility) == .requested)
    }

    // MARK: Tap failures

    @Test func tapFailuresBelowThresholdStayGranted() {
        var flow = makeFlow()
        grantAll(&flow)
        flow.recordTap(running: false)
        flow.recordTap(running: false)
        #expect(!flow.isTapFailing)
        #expect(flow.status(of: .accessibility) == .granted)
    }

    @Test func thresholdFailuresNeedRelaunch() {
        var flow = makeFlow()
        grantAll(&flow)
        for _ in 0..<3 { flow.recordTap(running: false) }
        #expect(flow.isTapFailing)
        #expect(flow.status(of: .accessibility) == .needsRelaunch)
        #expect(flow.status(of: .inputMonitoring) == .needsRelaunch)
        #expect(!flow.isComplete)
    }

    @Test func twoFailuresSpreadOverGraceNeedRelaunch() {
        var flow = makeFlow()
        grantAll(&flow)
        flow.recordTap(running: false)
        clock.advance(4)
        flow.recordTap(running: false)
        #expect(!flow.isTapFailing)
        clock.advance(1)
        #expect(flow.isTapFailing)
    }

    @Test func singleSlowFailureIsNotEnough() {
        var flow = makeFlow()
        grantAll(&flow)
        flow.recordTap(running: false)
        clock.advance(60)
        #expect(!flow.isTapFailing)
    }

    @Test func tapFailuresIgnoredUntilBothGranted() {
        var flow = makeFlow()
        provider.granted = [.accessibility]
        flow.refresh()
        for _ in 0..<5 { flow.recordTap(running: false) }
        provider.granted = Set(PermissionKind.allCases)
        flow.refresh()
        #expect(!flow.isTapFailing)
    }

    @Test func tapSuccessClearsFailures() {
        var flow = makeFlow()
        grantAll(&flow)
        for _ in 0..<3 { flow.recordTap(running: false) }
        flow.recordTap(running: true)
        #expect(flow.isComplete)
        flow.recordTap(running: false)
        #expect(!flow.isTapFailing)
    }

    @Test func revocationResetsFailureCount() {
        var flow = makeFlow()
        grantAll(&flow)
        for _ in 0..<2 { flow.recordTap(running: false) }
        provider.granted = []
        flow.refresh()
        grantAll(&flow)
        flow.recordTap(running: false)
        #expect(!flow.isTapFailing)
    }

    @Test func failingAgainAfterRecentRelaunchIsStale() {
        var flow = makeFlow()
        grantAll(&flow)
        for _ in 0..<3 { flow.recordTap(running: false) }
        flow.willRelaunch()

        // The new process loads the persisted memory.
        clock.advance(2)
        var relaunched = makeFlow(memory: flow.memory)
        for _ in 0..<3 { relaunched.recordTap(running: false) }
        #expect(relaunched.status(of: .accessibility) == .stale)

        relaunched.recordTap(running: true)
        #expect(relaunched.memory.relaunchedAt == nil)
        #expect(relaunched.isComplete)
    }

    @Test func failedRelaunchKeepsNeedsRelaunch() {
        var flow = makeFlow()
        grantAll(&flow)
        for _ in 0..<3 { flow.recordTap(running: false) }
        flow.willRelaunch()
        flow.relaunchFailed()
        #expect(flow.status(of: .accessibility) == .needsRelaunch)
    }

    @Test func oldRelaunchDoesNotMakeFailuresStale() {
        var flow = makeFlow()
        flow.willRelaunch()
        clock.advance(600)
        grantAll(&flow)
        for _ in 0..<3 { flow.recordTap(running: false) }
        #expect(flow.status(of: .accessibility) == .needsRelaunch)
    }

    @Test func memoryRoundTripsThroughJSON() throws {
        let memory = PermissionFlow.Memory(grantedIdentity: [.inputMonitoring: "abc"], relaunchedAt: Date(timeIntervalSince1970: 10))
        let decoded = try JSONDecoder().decode(PermissionFlow.Memory.self, from: JSONEncoder().encode(memory))
        #expect(decoded == memory)
    }

    // MARK: Onboarding steps

    @Test func stepsFollowPermissionsInOrder() {
        var flow = makeFlow()
        #expect(flow.onboardingStep(hasStarted: false, practiceFinished: false) == .welcome)
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: false) == .accessibility)

        provider.granted = [.inputMonitoring]
        flow.refresh()
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: false) == .accessibility)

        provider.granted = [.accessibility]
        flow.refresh()
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: false) == .inputMonitoring)

        grantAll(&flow)
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: false) == .tryIt)
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: true) == .done)
        #expect(flow.onboardingStep(hasStarted: false, practiceFinished: true) == .welcome)
    }

    @Test func failingTapHoldsOnTryIt() {
        var flow = makeFlow()
        grantAll(&flow)
        for _ in 0..<3 { flow.recordTap(running: false) }
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: true) == .tryIt)
    }

    @Test func staleAfterUpdateReturnsToThatPermissionStep() {
        let memory = PermissionFlow.Memory(grantedIdentity: [.accessibility: "old", .inputMonitoring: "old"])
        provider.granted = [.accessibility]
        let flow = makeFlow(identity: "new", memory: memory)
        #expect(flow.onboardingStep(hasStarted: true, practiceFinished: true) == .inputMonitoring)
        #expect(OnboardingStep.inputMonitoring.permission == .inputMonitoring)
        #expect(OnboardingStep.tryIt.permission == nil)
    }
}

@Suite("Guide placement")
struct GuidePlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 260, height: 120)

    @Test func dockedRightOfWindow() {
        let window = CGRect(x: 200, y: 100, width: 700, height: 600)
        let frame = GuidePlacement.frame(size: size, beside: window, visibleFrames: [screen])
        #expect(frame.minX == window.maxX + 12)
        #expect(frame.maxY == window.maxY - 64)
    }

    @Test func dockedLeftWhenRightIsFull() {
        let window = CGRect(x: 600, y: 100, width: 800, height: 600)
        let frame = GuidePlacement.frame(size: size, beside: window, visibleFrames: [screen])
        #expect(frame.maxX == window.minX - 12)
    }

    @Test func insideWindowWhenNoRoomEitherSide() {
        let window = CGRect(x: 10, y: 50, width: 1420, height: 800)
        let frame = GuidePlacement.frame(size: size, beside: window, visibleFrames: [screen])
        #expect(window.contains(frame))
        #expect(screen.contains(frame))
    }

    @Test func usesScreenHoldingTheWindow() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 1500, y: 200, width: 700, height: 600)
        let frame = GuidePlacement.frame(size: size, beside: window, visibleFrames: [screen, second])
        #expect(second.contains(frame))
        #expect(frame.minX == window.maxX + 12)
    }

    @Test func clampsTallWindowTop() {
        let window = CGRect(x: 100, y: 0, width: 600, height: 875)
        let frame = GuidePlacement.frame(size: CGSize(width: 260, height: 900), beside: window, visibleFrames: [screen])
        #expect(frame.minY == screen.maxY - 900)
    }

    @Test func fallsBackToBottomRight() {
        let frame = GuidePlacement.frame(size: size, beside: nil, visibleFrames: [screen])
        #expect(frame.maxX == screen.maxX - 24)
        #expect(frame.minY == screen.minY + 24)
    }

    @Test func fallsBackToBottomRightOfTheFirstScreen() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let frame = GuidePlacement.frame(size: size, beside: nil, visibleFrames: [screen, second])
        #expect(screen.contains(frame))
        #expect(frame.minY == screen.minY + 24)
    }
}
