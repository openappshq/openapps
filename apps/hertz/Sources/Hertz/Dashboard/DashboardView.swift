import AppKit
import HertzCore
import OpenAppsLicensing
import SwiftUI

/// The menu-bar dropdown: a scrolling stack of glass cards, one per reading,
/// with the health score first and the app's own controls in a fixed footer.
/// While the license keeps the readings off, the stack is one card saying
/// why (`LicenseCard`); the footer stays.
struct DashboardView: View {
    static let width: CGFloat = 400

    let model: MetricsModel
    let preferences: Preferences
    let license: LicenseStatus
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
        // Projected now, on every body: the card appears the moment a
        // deadline passes, whether or not a timer has fired yet.
        if let restriction = license.restriction() {
            // One card, as tall as it needs: nothing to scroll.
            VStack(spacing: 0) {
                LicenseCard(restriction: restriction, status: license)
                    .padding(Brand.Space.s12)
                Divider()
                FooterBar(showSettings: showSettings)
            }
            .frame(width: Self.width)
        } else {
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(spacing: Brand.Space.s8) {
                        readings
                    }
                    .padding(Brand.Space.s12)
                }
                Divider()
                FooterBar(showSettings: showSettings)
            }
            .frame(width: Self.width, height: menuHeight)
        }
    }

    @ViewBuilder private var readings: some View {
        HealthCard(hardware: model.hardware, health: model.health, badge: license.badge(), openLicense: license.openLicense)
        if preferences.showsDiagnosis {
            // The copy actions are the model's: they decide at click time
            // (access then, the sample then), never from text captured here.
            DiagnosisCard(insights: model.diagnostics,
                          records: model.flightRecorder,
                          copyReport: model.copyDiagnosticReport)
        }
        if preferences.showsSleepBlockers, model.powerAssertions.hasBlockers {
            SleepBlockersCard(snapshot: model.powerAssertions,
                              copyReport: model.copySleepBlockersReport,
                              copyGroup: model.copySleepBlockerDetails(pid:),
                              revealGroup: model.revealSleepBlocker(pid:))
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
            ProcessCard(roots: model.processTree,
                        copyDetails: model.copyProcessDetails(pid:),
                        revealProcess: model.revealProcess(pid:))
        }
        if preferences.showsCleanupScout {
            CleanupCard(model: cleanup)
        }
    }
}

// MARK: - Health

/// The score in display type, its word beside it, and the machine underneath.
/// In official builds the license pill sits above the score while there is
/// something to say (the trial's remaining time); licensed, the card is as
/// it always was.
private struct HealthCard: View {
    let hardware: HardwareInfo
    let health: HealthSummary
    let badge: LicenseBadge.Label?
    let openLicense: () -> Void

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
            if let badge {
                HStack {
                    LicensePill(label: badge, action: openLicense)
                    Spacer(minLength: 0)
                }
            }
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
