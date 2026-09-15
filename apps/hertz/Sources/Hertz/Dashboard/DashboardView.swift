import AppKit
import HertzCore
import SwiftUI

/// The menu-bar dropdown: a scrolling stack of glass cards, one per reading,
/// with the health score first and the app's own controls in a fixed footer.
struct DashboardView: View {
    static let width: CGFloat = 400

    let model: MetricsModel
    let preferences: Preferences
    let showSettings: () -> Void
    @State private var cleanup = CleanupModel()

    /// As tall as the screen the pointer is on allows, within limits, so the
    /// process list gets room on a big display without spilling on a small one.
    private var menuHeight: CGFloat {
        let pointer = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { screen in
            NSMouseInRect(pointer, screen.frame, false)
        } ?? NSScreen.main
        let visibleHeight = activeScreen?.visibleFrame.height ?? 720
        return max(440, min(760, visibleHeight - 48))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: Brand.Space.s8) {
                    HealthCard(hardware: model.hardware, health: model.health)
                    if preferences.showsDiagnosis {
                        DiagnosisCard(insights: model.diagnostics,
                                      records: model.flightRecorder,
                                      report: model.diagnosticReport)
                    }
                    if preferences.showsSleepBlockers, model.powerAssertions.hasBlockers {
                        SleepBlockersCard(snapshot: model.powerAssertions)
                    }
                    CPUCard(cpu: model.cpu, history: model.cpuHistory, sensors: model.sensors)
                    MemoryCard(memory: model.memory, history: model.memoryHistory)
                    HStack(alignment: .top, spacing: Brand.Space.s8) {
                        DiskCard(disk: model.disk)
                        NetworkCard(network: model.network, history: model.networkHistory)
                    }
                    if model.battery.present || !model.deviceBatteries.isEmpty {
                        BatteryCard(battery: model.battery, devices: model.deviceBatteries)
                    }
                    if preferences.showsProcesses {
                        ProcessCard(roots: model.processTree)
                    }
                    if preferences.showsCleanupScout {
                        CleanupCard(model: cleanup)
                    }
                }
                .padding(Brand.Space.s12)
            }
            Divider()
            FooterBar(showSettings: showSettings)
        }
        .frame(width: Self.width, height: menuHeight)
    }
}

// MARK: - Health

/// The score in display type, its word beside it, and the machine underneath.
private struct HealthCard: View {
    let hardware: HardwareInfo
    let health: HealthSummary

    private var uptime: String {
        Format.duration(seconds: Int(Date().timeIntervalSince(hardware.bootTime)))
    }

    private var specs: String {
        var parts: [String] = []
        if !hardware.chip.isEmpty { parts.append(hardware.chip) }
        if hardware.pCores > 0 || hardware.eCores > 0 {
            parts.append("\(hardware.pCores)P + \(hardware.eCores)E")
        }
        parts.append("\(hardware.memoryGB) GB")
        if !hardware.osVersion.isEmpty { parts.append("macOS \(hardware.osVersion)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s8) {
                Text("\(health.score)")
                    .font(Brand.display(34))
                    .foregroundStyle(Brand.textPrimary)
                    .monospacedDigit()
                Text(health.label)
                    .font(Brand.body(15, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
                Circle()
                    .fill(Level.health(health.score).color)
                    .frame(width: 7, height: 7)
                    .offset(y: -2)
                Spacer(minLength: Brand.Space.s8)
                MonoLabel("up \(uptime)")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Health \(health.score), \(health.label), up \(uptime)")
            DetailLine(specs)
        }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    let showSettings: () -> Void

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "Hertz \($0)" } ?? "Hertz"
    }

    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            Image(nsImage: AppResources.menuBarImage())
                .renderingMode(.template)
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            MonoLabel(version)
            Spacer()
            Button("Settings…", action: showSettings)
                .buttonStyle(LinkButtonStyle())
                .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(LinkButtonStyle())
                .keyboardShortcut("q")
        }
        .padding(.horizontal, Brand.Space.s16)
        .padding(.vertical, Brand.Space.s8)
        .frame(minHeight: 40)
    }
}
