import XCTest
@testable import HertzCore

final class HealthScoreTests: XCTestCase {
    @MainActor func testIdleMachineScoresExcellent() {
        let health = computeHealth(cpu: CPUSnapshot(total: 8, thermalPressure: .nominal),
                                   memory: MemorySnapshot(pressurePercent: 30),
                                   disk: DiskSnapshot(usedPercent: 50),
                                   battery: BatterySnapshot(present: true, healthPercent: 95))
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.label, "Excellent")
    }

    @MainActor func testDiskWeighsHeaviest() {
        let cpuBusy = computeHealth(cpu: CPUSnapshot(total: 100, thermalPressure: .nominal),
                                    memory: MemorySnapshot(), disk: DiskSnapshot(), battery: BatterySnapshot())
        let diskFull = computeHealth(cpu: CPUSnapshot(thermalPressure: .nominal),
                                     memory: MemorySnapshot(), disk: DiskSnapshot(usedPercent: 99), battery: BatterySnapshot())
        XCTAssertEqual(cpuBusy.score, 86)   // 40 over the threshold × 0.35
        XCTAssertEqual(diskFull.score, 78)  // 14 over the threshold × 1.6
    }

    @MainActor func testScoreNeverLeavesZeroToHundred() {
        let worst = computeHealth(cpu: CPUSnapshot(total: 100, thermalPressure: .critical),
                                  memory: MemorySnapshot(pressurePercent: 100),
                                  disk: DiskSnapshot(usedPercent: 100),
                                  battery: BatterySnapshot(present: true, healthPercent: 10))
        XCTAssertEqual(worst.score, 0)
        XCTAssertEqual(worst.label, "Poor")
    }

    @MainActor func testAbsentBatteryIsNotPenalised() {
        let health = computeHealth(cpu: CPUSnapshot(thermalPressure: .nominal), memory: MemorySnapshot(),
                                   disk: DiskSnapshot(), battery: BatterySnapshot(present: false, healthPercent: 0))
        XCTAssertEqual(health.score, 100)
    }
}

final class DiagnosisTests: XCTestCase {
    @MainActor private func context(cpu: CPUSnapshot = CPUSnapshot(thermalPressure: .nominal),
                         memory: MemorySnapshot = MemorySnapshot(pressureLevel: .normal),
                         disk: DiskSnapshot = DiskSnapshot(usedPercent: 40, fsType: "apfs"),
                         battery: BatterySnapshot = BatterySnapshot(),
                         tree: [ProcessNode] = []) -> DiagnosticContext {
        DiagnosticContext(cpu: cpu, memory: memory, disk: disk, network: NetSnapshot(),
                          battery: battery, sensors: SensorSnapshot(), processTree: tree,
                          hardware: HardwareInfo(chip: "Apple M4", memoryGB: 16),
                          health: computeHealth(cpu: cpu, memory: memory, disk: disk, battery: battery))
    }

    @MainActor func testBalancedSystemHasOneInfoInsight() {
        let insights = diagnose(context())
        XCTAssertEqual(insights.map(\.id), ["balanced"])
        XCTAssertEqual(insights.first?.severity, .info)
    }

    @MainActor func testCriticalInsightsComeFirstAndAtMostThreeAreKept() {
        let tree = buildProcessTree([
            ProcSample(pid: 10, ppid: 1, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                       memory: 3 * 1_073_741_824, cpu: 90),
        ])
        let insights = diagnose(context(
            cpu: CPUSnapshot(total: 92, thermalPressure: .moderate),
            memory: MemorySnapshot(pressurePercent: 95, pressureLevel: .critical, swapUsed: 2_147_483_648),
            disk: DiskSnapshot(free: 1_073_741_824, usedPercent: 96, fsType: "apfs"),
            battery: BatterySnapshot(present: true, healthPercent: 70, cycleCount: 900),
            tree: tree
        ))
        XCTAssertEqual(insights.count, 3)
        XCTAssertTrue(insights.allSatisfy { $0.severity == .critical })
        XCTAssertEqual(insights.map(\.id).sorted(), ["cpu", "disk", "memory"])
        let cpu = insights.first { $0.id == "cpu" }
        XCTAssertTrue(cpu?.detail.contains("Xcode is leading at 90.0%") == true, cpu?.detail ?? "")
        let memory = insights.first { $0.id == "memory" }
        XCTAssertTrue(memory?.detail.contains("Xcode is the largest app at 3.0 GB") == true, memory?.detail ?? "")
    }

    @MainActor func testWarningThresholdsUseTheKernelPressureLevel() {
        let insights = diagnose(context(memory: MemorySnapshot(pressurePercent: 50, pressureLevel: .warning)))
        XCTAssertEqual(insights.first?.id, "memory")
        XCTAssertEqual(insights.first?.severity, .warning)
    }

    @MainActor func testBatteryInsightsNeedAPresentBattery() {
        let absent = diagnose(context(battery: BatterySnapshot(present: false, healthPercent: 50, powerWatts: -30)))
        XCTAssertEqual(absent.map(\.id), ["balanced"])
        let draining = diagnose(context(battery: BatterySnapshot(present: true, onAC: false, healthPercent: 90, powerWatts: -30)))
        XCTAssertEqual(draining.map(\.id), ["battery-draw"])
    }

    @MainActor func testReportListsHardwareDiagnosisAndTopProcesses() {
        let tree = buildProcessTree([
            ProcSample(pid: 10, ppid: 1, name: "Safari", path: "", memory: 800 * 1_048_576, cpu: 12),
            ProcSample(pid: 11, ppid: 10, name: "WebContent", path: "", memory: 400 * 1_048_576, cpu: 8),
            ProcSample(pid: 20, ppid: 1, name: "Terminal", path: "", memory: 100 * 1_048_576, cpu: 1),
        ])
        let report = diagnosticReport(context(tree: tree), generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.hasPrefix("Hertz diagnostic snapshot\n"))
        XCTAssertTrue(report.contains("Hardware: Apple M4 · 16 GB RAM"))
        XCTAssertTrue(report.contains("- System looks balanced:"))
        XCTAssertTrue(report.contains("- Safari: 20.0% CPU, 1.2 GB"), report)
        XCTAssertTrue(report.contains("Battery: not present"))
        XCTAssertFalse(report.contains("WebContent"), "only roots are listed")
    }
}
