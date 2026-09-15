import XCTest
@testable import HertzCore

final class ProcessTreeTests: XCTestCase {
    @MainActor private func sample(_ pid: pid_t, parent: pid_t, _ name: String, cpu: Double = 0, memory: UInt64 = 0) -> ProcSample {
        ProcSample(pid: pid, ppid: parent, name: name, path: "", memory: memory, cpu: cpu)
    }

    @MainActor func testChildrenNestUnderTheirAppAndTotalsSumTheSubtree() {
        let roots = buildProcessTree([
            sample(100, parent: 1, "Safari", cpu: 5, memory: 100),
            sample(101, parent: 100, "WebContent", cpu: 20, memory: 300),
            sample(102, parent: 101, "Networking", cpu: 1, memory: 50),
            sample(200, parent: 1, "Terminal", cpu: 2, memory: 40),
        ])
        XCTAssertEqual(roots.map(\.sample.name), ["Safari", "Terminal"])
        let safari = roots[0]
        XCTAssertEqual(safari.processCount, 3)
        XCTAssertEqual(safari.subtreeCPU, 26)
        XCTAssertEqual(safari.subtreeMemory, 450)
        XCTAssertEqual(safari.children.map(\.sample.name), ["WebContent"])
        XCTAssertEqual(safari.children[0].children.map(\.sample.name), ["Networking"])
    }

    @MainActor func testLaunchdChildrenStayRootsAndOrphansAreRootsToo() {
        let roots = buildProcessTree([
            sample(1, parent: 0, "launchd"),
            sample(300, parent: 1, "loginwindow"),
            sample(400, parent: 999, "orphan"), // parent not in the sample
        ])
        XCTAssertEqual(roots.map(\.sample.pid), [1, 300, 400])
        XCTAssertTrue(roots.allSatisfy { $0.children.isEmpty })
    }

    @MainActor func testCyclesAreCappedInsteadOfRecursingForever() {
        // Two processes claiming each other as parent (can only happen with a
        // stale sample); neither may hang the build.
        let roots = buildProcessTree([
            sample(10, parent: 11, "a"),
            sample(11, parent: 10, "b"),
        ])
        XCTAssertTrue(roots.isEmpty)
    }
}

final class FormatTests: XCTestCase {
    @MainActor func testBytesPickTheUnitBySize() {
        XCTAssertEqual(Format.bytes(512), "0 KB")
        XCTAssertEqual(Format.bytes(1536), "2 KB")
        XCTAssertEqual(Format.bytes(300 * 1024), "300 KB")
        XCTAssertEqual(Format.bytes(5 * 1_048_576), "5 MB")
        XCTAssertEqual(Format.bytes(1_610_612_736), "1.5 GB")
        XCTAssertEqual(Format.gigabytes(512 * 1_073_741_824), "512 GB")
    }

    @MainActor func testRatesRoundBelowAKilobyteToZero() {
        XCTAssertEqual(Format.rate(900), "0 KB/s")
        XCTAssertEqual(Format.rate(40 * 1024), "40 KB/s")
        XCTAssertEqual(Format.rate(2.5 * 1_048_576), "2.5 MB/s")
    }

    @MainActor func testDurations() {
        XCTAssertEqual(Format.minutes(-1), "—")
        XCTAssertEqual(Format.minutes(45), "45m")
        XCTAssertEqual(Format.minutes(65), "1h 05m")
        XCTAssertEqual(Format.duration(seconds: 59), "0m")
        XCTAssertEqual(Format.duration(seconds: 3 * 3600 + 120), "3h 2m")
        XCTAssertEqual(Format.duration(seconds: 2 * 86400 + 5 * 3600), "2d 5h")
        XCTAssertEqual(Format.duration(seconds: -10), "0m")
    }

    @MainActor func testPercent() {
        XCTAssertEqual(Format.percent(14.94), "15%")
        XCTAssertEqual(Format.percent(14.94, decimals: 1), "14.9%")
    }
}

final class MenuBarReadoutTests: XCTestCase {
    @MainActor func testReadoutFollowsTheChosenMetric() {
        let cpu = CPUSnapshot(total: 14.6)
        let memory = MemorySnapshot(usedPercent: 66.2)
        XCTAssertEqual(MenuBarReadout.cpu.text(cpu: cpu, memory: memory), "15%")
        XCTAssertEqual(MenuBarReadout.memory.text(cpu: cpu, memory: memory), "66%")
        XCTAssertEqual(MenuBarReadout.none.text(cpu: cpu, memory: memory), "")
    }

    @MainActor func testEveryCaseHasATitleAndRoundTripsItsRawValue() {
        for readout in MenuBarReadout.allCases {
            XCTAssertFalse(readout.title.isEmpty)
            XCTAssertEqual(MenuBarReadout(rawValue: readout.rawValue), readout)
        }
    }
}
