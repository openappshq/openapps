import Foundation
import HertzCore
import Observation

/// One recorded change of the leading diagnosis, so the dashboard can say
/// what became slow a moment ago instead of only showing live gauges.
struct FlightRecord: Identifiable {
    let id = UUID()
    let date: Date
    let severity: DiagnosticSeverity
    let title: String
    let detail: String
}

/// Holds the latest metrics snapshot. Observed by the dashboard and the menu
/// bar readout; refreshed on a two-second timer on the main run loop.
@Observable
final class MetricsModel {
    static let refreshInterval: TimeInterval = 2

    var cpu = CPUSnapshot()
    var memory = MemorySnapshot()
    var disk = DiskSnapshot()
    var network = NetSnapshot()
    var battery = BatterySnapshot()
    var deviceBatteries: [DeviceBattery] = []
    var powerAssertions = PowerAssertionsSnapshot()
    var processes: [ProcSample] = []
    var processTree: [ProcessNode] = []
    var cpuHistory: [Double] = []     // recent CPU totals for the sparkline
    var memoryHistory: [Double] = []  // recent memory-pressure % for the sparkline
    var networkHistory: [Double] = [] // recent total throughput for the sparkline
    var hardware = HardwareInfo()
    var health = HealthSummary()
    var sensors = SensorSnapshot()
    var diagnostics: [DiagnosticInsight] = []
    var flightRecorder: [FlightRecord] = []

    private let historyLimit = 44
    private let flightRecorderLimit = 12
    private var lastFlightEventKey = ""

    @ObservationIgnored private let system = SystemMetrics()
    @ObservationIgnored private let batteryReader = BatteryMetrics()
    @ObservationIgnored private let powerAssertionReader = PowerAssertionReader()
    @ObservationIgnored private let collector = ProcessCollector()
    @ObservationIgnored private let smc = SMCReader()
    @ObservationIgnored private var timer: Timer?

    init() {
        hardware = system.hardware() // static: read once
        refresh() // first read; CPU and network rates show 0 until the second tick
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        cpu = system.cpu()
        memory = system.memory()
        disk = system.disk()
        network = system.network()
        battery = batteryReader.read()
        deviceBatteries = batteryReader.accessories()
        sensors = smc.read()
        processes = collector.sample().sorted { $0.cpu > $1.cpu }
        powerAssertions = powerAssertionReader.read(processes: processes)
        processTree = buildProcessTree(processes)
        health = computeHealth(cpu: cpu, memory: memory, disk: disk, battery: battery)
        diagnostics = diagnose(diagnosticContext)
        recordFlightEvent()

        cpuHistory = trimmed(cpuHistory + [cpu.total])
        memoryHistory = trimmed(memoryHistory + [memory.pressurePercent])
        networkHistory = trimmed(networkHistory + [network.down + network.up])
    }

    /// Keep only the most recent `historyLimit` samples.
    private func trimmed(_ values: [Double]) -> [Double] {
        values.count > historyLimit ? Array(values.suffix(historyLimit)) : values
    }

    var diagnosticContext: DiagnosticContext {
        DiagnosticContext(cpu: cpu, memory: memory, disk: disk,
                          network: network, battery: battery,
                          sensors: sensors, processTree: processTree,
                          hardware: hardware, health: health)
    }

    /// The copyable snapshot: the report plus the recent events.
    var diagnosticReport: String {
        var report = HertzCore.diagnosticReport(diagnosticContext)
        if !flightRecorder.isEmpty {
            report += "\n\nRecent events:"
            for event in flightRecorder.prefix(6) {
                report += "\n- \(eventDate.string(from: event.date)): "
                    + "\(event.title) — \(event.detail)"
            }
        }
        return report
    }

    private func recordFlightEvent() {
        guard let leading = diagnostics.first,
              leading.severity != .info else {
            lastFlightEventKey = ""
            return
        }

        let key = "\(leading.id)-\(leading.severity.rawValue)"
        guard key != lastFlightEventKey else { return }
        lastFlightEventKey = key

        flightRecorder.insert(FlightRecord(date: Date(),
                                           severity: leading.severity,
                                           title: leading.title,
                                           detail: leading.detail),
                              at: 0)
        if flightRecorder.count > flightRecorderLimit {
            flightRecorder.removeLast(flightRecorder.count - flightRecorderLimit)
        }
    }
}

private let eventDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
}()
