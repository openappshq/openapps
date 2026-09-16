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

/// The collectors behind `MetricsModel`, as closures so a test can count
/// reads with inert stand-ins; the app uses `.live`, the real readers.
struct MetricsReaders {
    var hardware: () -> HardwareInfo
    var cpu: () -> CPUSnapshot
    var memory: () -> MemorySnapshot
    var disk: () -> DiskSnapshot
    var network: () -> NetSnapshot
    var battery: () -> BatterySnapshot
    var accessories: () -> [DeviceBattery]
    var sensors: () -> SensorSnapshot
    var processes: () -> [ProcSample]
    var powerAssertions: ([ProcSample]) -> PowerAssertionsSnapshot

    /// Mach, libproc, IOKit, the SMC and CoreWLAN. Created lazily: a model
    /// that never gets access never opens the SMC or samples a process.
    static var live: MetricsReaders {
        let system = SystemMetrics()
        let battery = BatteryMetrics()
        let power = PowerAssertionReader()
        let collector = ProcessCollector()
        let smc = SMCReader()
        return MetricsReaders(
            hardware: { system.hardware() },
            cpu: { system.cpu() },
            memory: { system.memory() },
            disk: { system.disk() },
            network: { system.network() },
            battery: { battery.read() },
            accessories: { battery.accessories() },
            sensors: { smc.read() },
            processes: { collector.sample() },
            powerAssertions: { power.read(processes: $0) }
        )
    }
}

/// Holds the latest metrics snapshot. Observed by the dashboard and the menu
/// bar readout; refreshed on a two-second timer on the main run loop.
///
/// Collection is the app's core feature (LICENSING.md): it runs only while
/// `access()` says so, asked afresh on every read — the timer is a wake-up,
/// never the authorisation. The model starts with nothing collected; the
/// first read happens once the app grants access. When access lapses the
/// last sample is dropped, so nothing collected under a grant is shown or
/// exported after it.
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
    /// A sample collected under the current access is held. False until
    /// the first read, and again whenever access lapses.
    private(set) var hasSample = false

    private let historyLimit = 44
    private let flightRecorderLimit = 12
    private var lastFlightEventKey = ""

    /// Created on the first read, so a restricted launch never opens the
    /// SMC or the process collector.
    @ObservationIgnored private lazy var readers: MetricsReaders = makeReaders()
    @ObservationIgnored private let makeReaders: () -> MetricsReaders
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hardwareRead = false
    /// The entitlement, projected now. Set by the app before `start`; a
    /// build without licensing leaves it always true.
    @ObservationIgnored var access: () -> Bool = { true }
    /// Reads made, for tests.
    @ObservationIgnored private(set) var readCount = 0
    /// Where the export actions (`MetricsExports.swift`) send text and
    /// reveal files; the real pasteboard and Finder unless a test says so.
    @ObservationIgnored var clipboard: (String) -> Void = { ExportSinks.clipboard($0) }
    @ObservationIgnored var reveal: (URL) -> Void = { ExportSinks.reveal($0) }

    init(readers: @escaping () -> MetricsReaders = { .live }) {
        makeReaders = readers
    }

    /// Whether the readings may be read or shown right now.
    var hasAccess: Bool { access() }

    /// Starts (or keeps) the periodic collection, reading at once when
    /// access allows it. Called when the app grants access; harmless while
    /// running.
    func start() {
        tick()
        // No timer while access is denied: the app starts again on a grant.
        guard timer == nil, access() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop.
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops the periodic collection and drops the last sample. Called when
    /// the app withdraws access; `tick` does the same on its own when it
    /// finds access gone before the app said so.
    func stop() {
        timer?.invalidate()
        timer = nil
        clearSample()
    }

    /// One collection, if access allows it now; otherwise the sample goes
    /// and the timer with it, until the app grants access again.
    func tick() {
        guard access() else {
            if timer != nil || hasSample { stop() }
            return
        }
        refresh()
    }

    private func refresh() {
        readCount += 1
        if !hardwareRead {
            hardware = readers.hardware() // static: read once
            hardwareRead = true
        }
        cpu = readers.cpu()
        memory = readers.memory()
        disk = readers.disk()
        network = readers.network()
        battery = readers.battery()
        deviceBatteries = readers.accessories()
        sensors = readers.sensors()
        processes = readers.processes().sorted { $0.cpu > $1.cpu }
        powerAssertions = readers.powerAssertions(processes)
        processTree = buildProcessTree(processes)
        health = computeHealth(cpu: cpu, memory: memory, disk: disk, battery: battery)
        diagnostics = diagnose(diagnosticContext)
        recordFlightEvent()

        cpuHistory = trimmed(cpuHistory + [cpu.total])
        memoryHistory = trimmed(memoryHistory + [memory.pressurePercent])
        networkHistory = trimmed(networkHistory + [network.down + network.up])
        hasSample = true
    }

    /// Back to the empty model: nothing read under a lapsed grant survives.
    private func clearSample() {
        guard hasSample else { return }
        cpu = CPUSnapshot()
        memory = MemorySnapshot()
        disk = DiskSnapshot()
        network = NetSnapshot()
        battery = BatterySnapshot()
        deviceBatteries = []
        powerAssertions = PowerAssertionsSnapshot()
        processes = []
        processTree = []
        cpuHistory = []
        memoryHistory = []
        networkHistory = []
        health = HealthSummary()
        sensors = SensorSnapshot()
        diagnostics = []
        flightRecorder = []
        lastFlightEventKey = ""
        hasSample = false
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

    /// What the license allows a copied snapshot to say about the readings
    /// when there are none: the export paths use it instead of a report.
    static let readingsUnavailable = "Readings: not collected (the license doesn’t allow them right now)."

    /// The report plus the recent events — only while access allows it now
    /// and a sample is held; otherwise one line saying why there is none.
    /// Copy Diagnostics reads it inside its action; the dashboard's Copy
    /// snapshot goes through `copyDiagnosticReport()` at click time.
    var diagnosticReport: String {
        guard access(), hasSample else { return Self.readingsUnavailable }
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
