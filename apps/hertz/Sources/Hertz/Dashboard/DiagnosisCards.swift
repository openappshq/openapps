import AppKit
import HertzCore
import SwiftUI

// MARK: - Diagnosis

/// The current bottleneck, the last few pressure changes, and a copyable
/// snapshot for support threads.
struct DiagnosisCard: View {
    let insights: [DiagnosticInsight]
    let records: [FlightRecord]
    /// Runs at click time and decides then what is copied (the report as
    /// of now, or the refusal line); the view holds no report text.
    let copyReport: () -> MetricsModel.Export
    @State private var copied = false
    @State private var refused = false

    var body: some View {
        Card {
            CardHeader("Diagnosis") {
                Button {
                    refused = copyReport() == .refused
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CardActionStyle())
                .help("Copy a diagnostic snapshot")
                .accessibilityLabel(copied ? "Copied" : "Copy diagnostic snapshot")
            }
            if copied, refused {
                Note(MetricsModel.exportRefused)
            }

            ForEach(insights.prefix(3)) { insight in
                InsightRow(insight: insight)
            }

            if !records.isEmpty {
                VStack(alignment: .leading, spacing: Brand.Space.s4) {
                    MonoLabel("Recent")
                    ForEach(records.prefix(3)) { record in
                        FlightRecordRow(record: record)
                    }
                }
                .padding(.top, Brand.Space.s4)
            }
        }
    }
}

private struct InsightRow: View {
    let insight: DiagnosticInsight

    private var level: Level { Level.severity(insight.severity) }

    private var icon: String {
        switch insight.severity {
        case .info: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Space.s8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(level.color)
                .frame(width: 14)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(Brand.body(13, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
                Text(insight.detail)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FlightRecordRow: View {
    let record: FlightRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s8) {
            Text(shortEventTime.string(from: record.date))
                .font(Brand.mono(11))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 56, alignment: .leading)
            Circle()
                .fill(Level.severity(record.severity).color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(record.title)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sleep blockers

/// Apps and daemons holding sleep or the display awake. Read-only: Hertz
/// never clears another process's assertion.
struct SleepBlockersCard: View {
    let snapshot: PowerAssertionsSnapshot
    /// Gated at click time against the current sample (`MetricsExports.swift`).
    let copyReport: () -> MetricsModel.Export
    let copyGroup: (pid_t) -> MetricsModel.Export
    let revealGroup: (pid_t) -> MetricsModel.Export
    @State private var message: String?

    private var visibleGroups: [PowerAssertionGroup] {
        Array(snapshot.groups.prefix(4))
    }

    private var title: String {
        if snapshot.groups.count == 1 {
            return "\(snapshot.groups[0].displayName) is keeping the Mac awake"
        }
        return "\(snapshot.groups.count) processes are keeping the Mac awake"
    }

    private var detail: String {
        let system = snapshot.groups.filter(\.blocksSystemSleep).count
        let display = snapshot.groups.filter { !$0.blocksSystemSleep && $0.blocksDisplaySleep }.count
        if system > 0 && display > 0 {
            return "\(system) blocking sleep · \(display) blocking display sleep"
        }
        return system > 0 ? "Idle sleep is blocked" : "Display sleep is blocked"
    }

    var body: some View {
        Card {
            CardHeader("Sleep blockers") {
                Button {
                    message = copyReport().note
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(CardActionStyle())
                .help("Copy the sleep blocker report")
                .accessibilityLabel("Copy the sleep blocker report")
                Button {
                    PowerAssertionActions.openActivityMonitor()
                    message = "Opened Activity Monitor"
                } label: {
                    Image(systemName: "gauge.with.needle")
                }
                .buttonStyle(CardActionStyle())
                .help("Open Activity Monitor")
                .accessibilityLabel("Open Activity Monitor")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Brand.body(13, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            ForEach(visibleGroups) { group in
                SleepBlockerRow(group: group, copyGroup: copyGroup, revealGroup: revealGroup) { message = $0 }
            }

            if snapshot.groups.count > visibleGroups.count {
                Note("+\(snapshot.groups.count - visibleGroups.count) more")
            }
            if let message {
                Note(message)
            }
        }
    }
}

private struct SleepBlockerRow: View {
    let group: PowerAssertionGroup
    let copyGroup: (pid_t) -> MetricsModel.Export
    let revealGroup: (pid_t) -> MetricsModel.Export
    let onMessage: (String) -> Void

    private var duration: String {
        guard let start = group.longestRunningStart else { return "" }
        let minutes = max(0, Int(Date().timeIntervalSince(start))) / 60
        return minutes > 0 ? Format.minutes(minutes) : "<1m"
    }

    private var kind: String {
        if group.blocksSystemSleep { return "sleep" }
        if group.blocksDisplaySleep { return "display" }
        return "sleep"
    }

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            ProcessIcon(path: group.processPath)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.displayName)
                        .font(Brand.body(13, weight: 600))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    if group.assertions.count > 1 {
                        CountBadge(count: group.assertions.count)
                    }
                }
                Text(group.primaryLabel)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Brand.Space.s8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(kind)
                    .font(Brand.mono(10, medium: true))
                    .foregroundStyle(Brand.textSecondary)
                if !duration.isEmpty {
                    Text(duration)
                        .font(Brand.mono(11))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            // The row's pid names the blocker; what is copied or revealed is
            // looked up in the sample held at click time, under access then.
            Button {
                onMessage(copyGroup(group.pid).note)
            } label: {
                Label("Copy Blocker Details", systemImage: "doc.on.doc")
            }
            if MetricsModel.revealURL(forPath: group.processPath) != nil {
                Button {
                    onMessage(revealGroup(group.pid).note)
                } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                }
            }
            Button {
                PowerAssertionActions.openActivityMonitor()
                onMessage("Opened Activity Monitor")
            } label: {
                Label("Open Activity Monitor", systemImage: "gauge.with.needle")
            }
        }
    }
}
