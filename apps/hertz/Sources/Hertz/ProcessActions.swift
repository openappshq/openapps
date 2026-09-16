import AppKit
import Foundation
import HertzCore

/// Actions on a process row. Read-only on purpose: Hertz copies, reveals and
/// hands off to Activity Monitor, and never signals a process. A row's PID and
/// path are a snapshot, not an identity, and a reused PID must never be
/// terminated by mistake.

struct ProcessActionItem: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let path: String

    var id: pid_t { pid }
}

struct ProcessActionTarget: Identifiable, Equatable {
    let root: ProcessActionItem
    let items: [ProcessActionItem]

    var id: pid_t { root.pid }
    var descendantCount: Int { max(0, items.count - 1) }
    var includesDescendants: Bool { descendantCount > 0 }

    var title: String {
        root.name.isEmpty ? "pid \(root.pid)" : root.name
    }
}

extension ProcessNode {
    var processActionTarget: ProcessActionTarget {
        let allItems = flattenedProcessItems()
        return ProcessActionTarget(root: allItems[0], items: allItems)
    }

    private func flattenedProcessItems() -> [ProcessActionItem] {
        [ProcessActionItem(sample: sample)] + children.flatMap { $0.flattenedProcessItems() }
    }
}

private extension ProcessActionItem {
    init(sample: ProcSample) {
        self.init(pid: sample.pid, name: sample.name, path: sample.path)
    }
}

enum ProcessActions {
    /// One line per process: name, pid, path. Copied by
    /// `MetricsModel.copyProcessDetails`, which gates it on the current
    /// access and reads the current tree.
    static func details(_ target: ProcessActionTarget) -> String {
        target.items.map { item in
            let path = item.path.isEmpty ? "path unavailable" : item.path
            return "\(item.name)\tpid \(item.pid)\t\(path)"
        }.joined(separator: "\n")
    }

    static func openActivityMonitor() {
        PowerAssertionActions.openActivityMonitor()
    }
}
