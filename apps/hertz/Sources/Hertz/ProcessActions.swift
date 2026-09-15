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
    static func copyDetails(_ target: ProcessActionTarget) {
        let details = target.items.map { item in
            let path = item.path.isEmpty ? "path unavailable" : item.path
            return "\(item.name)\tpid \(item.pid)\t\(path)"
        }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }

    static func canReveal(_ target: ProcessActionTarget) -> Bool {
        revealURL(for: target.root) != nil
    }

    @discardableResult
    static func reveal(_ target: ProcessActionTarget) -> Bool {
        guard let url = revealURL(for: target.root) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    static func openActivityMonitor() {
        PowerAssertionActions.openActivityMonitor()
    }

    private static func revealURL(for item: ProcessActionItem) -> URL? {
        guard !item.path.isEmpty else { return nil }
        let path: String
        if let range = item.path.range(of: ".app/") {
            path = String(item.path[..<range.lowerBound]) + ".app"
        } else {
            path = item.path
        }
        return URL(fileURLWithPath: path)
    }


}
