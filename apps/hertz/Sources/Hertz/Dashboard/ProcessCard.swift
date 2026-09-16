import AppKit
import HertzCore
import SwiftUI

/// The process tree grouped by app, sortable by CPU or memory. Rows with
/// children expand on click; every row has copy, reveal and Activity Monitor
/// in its context menu. Hertz never terminates a process: a PID in a
/// two-second-old snapshot is not a safe target.
struct ProcessCard: View {
    let roots: [ProcessNode]
    /// Gated at click time against the current tree (`MetricsExports.swift`).
    let copyDetails: (pid_t) -> MetricsModel.Export
    let revealProcess: (pid_t) -> MetricsModel.Export
    @State private var sortByMemory = false
    @State private var expanded: Set<pid_t> = []
    @State private var message: String?

    private enum Layout {
        static let rowHeight: CGFloat = 22
        static let rowSpacing: CGFloat = 4
        static let visibleRoots = 8
        static let maxListHeight: CGFloat = 240
    }

    private func metric(_ node: ProcessNode) -> Double {
        sortByMemory ? Double(node.subtreeMemory) : node.subtreeCPU
    }

    /// The top roots plus the children of every expanded node, in display order.
    private var visibleRows: [(node: ProcessNode, depth: Int)] {
        var out: [(ProcessNode, Int)] = []
        for root in roots.sorted(by: { metric($0) > metric($1) }).prefix(Layout.visibleRoots) {
            append(root, depth: 0, into: &out)
        }
        return out
    }

    private func append(_ node: ProcessNode, depth: Int, into out: inout [(ProcessNode, Int)]) {
        out.append((node, depth))
        guard expanded.contains(node.id) else { return }
        for child in node.children.sorted(by: { metric($0) > metric($1) }) {
            append(child, depth: depth + 1, into: &out)
        }
    }

    var body: some View {
        let rows = visibleRows
        let listHeight = CGFloat(rows.count) * Layout.rowHeight + CGFloat(max(0, rows.count - 1)) * Layout.rowSpacing

        Card {
            CardHeader("Processes") {
                SortColumns(sortByMemory: $sortByMemory)
            }
            Group {
                if listHeight > Layout.maxListHeight {
                    ScrollView(.vertical) {
                        list(rows)
                    }
                    .frame(height: Layout.maxListHeight)
                } else {
                    list(rows)
                }
            }
            if let message {
                Note(message)
            }
        }
    }

    private func list(_ rows: [(node: ProcessNode, depth: Int)]) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ForEach(rows, id: \.node.id) { row in
                ProcessRow(node: row.node, depth: row.depth,
                           isExpanded: expanded.contains(row.node.id),
                           sortByMemory: sortByMemory,
                           copyDetails: copyDetails, revealProcess: revealProcess) {
                    if expanded.contains(row.node.id) {
                        expanded.remove(row.node.id)
                    } else {
                        expanded.insert(row.node.id)
                    }
                } onMessage: { text in
                    message = text
                }
                .frame(height: Layout.rowHeight)
            }
        }
    }

}

/// The two column headings double as the sort control.
private struct SortColumns: View {
    @Binding var sortByMemory: Bool

    var body: some View {
        HStack(spacing: Brand.Space.s4) {
            column("CPU", active: !sortByMemory, width: 52) { sortByMemory = false }
            column("MEM", active: sortByMemory, width: 62) { sortByMemory = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort by")
    }

    private func column(_ title: String, active: Bool, width: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if active {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                Text(title)
                    .font(Brand.mono(11, medium: active))
                    .tracking(0.6)
            }
            .foregroundStyle(active ? Brand.textPrimary : Brand.textSecondary)
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// One process row in the tree. Subtree totals on a parent; own values on a
/// leaf. Clicking a row with children expands it.
private struct ProcessRow: View {
    let node: ProcessNode
    let depth: Int
    let isExpanded: Bool
    let sortByMemory: Bool
    let copyDetails: (pid_t) -> MetricsModel.Export
    let revealProcess: (pid_t) -> MetricsModel.Export
    let onToggle: () -> Void
    let onMessage: (String) -> Void

    private var hasChildren: Bool { !node.children.isEmpty }

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            Group {
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Brand.textSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 9)

            ProcessIcon(path: node.sample.path)

            HStack(spacing: 5) {
                Text(node.sample.name)
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if hasChildren {
                    CountBadge(count: node.processCount)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.1f", node.subtreeCPU))
                .font(Brand.mono(12, medium: !sortByMemory))
                .foregroundStyle(sortByMemory ? Brand.textSecondary : Brand.textPrimary)
                .frame(width: 52, alignment: .trailing)
            Text(Format.bytes(node.subtreeMemory))
                .font(Brand.mono(12, medium: sortByMemory))
                .foregroundStyle(sortByMemory ? Brand.textPrimary : Brand.textSecondary)
                .frame(width: 62, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { if hasChildren { onToggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.sample.name), CPU \(String(format: "%.1f", node.subtreeCPU)) percent, memory \(Format.bytes(node.subtreeMemory))")
        .accessibilityAddTraits(hasChildren ? [.isButton] : [])
        .contextMenu {
            // The row's pid names the process; what is copied or revealed is
            // looked up in the tree held at click time, under access then.
            Button {
                onMessage(copyDetails(node.id).note)
            } label: {
                Label(hasChildren ? "Copy Tree PIDs and Paths" : "Copy PID and Path", systemImage: "doc.on.doc")
            }
            if MetricsModel.revealURL(forPath: node.sample.path) != nil {
                Button {
                    onMessage(revealProcess(node.id).note)
                } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                }
            }
            Divider()
            Button {
                ProcessActions.openActivityMonitor()
                onMessage("Opened Activity Monitor")
            } label: {
                Label("Open Activity Monitor", systemImage: "gauge.with.needle")
            }
        }
    }
}
