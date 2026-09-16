import AppKit
import Foundation
import HertzCore

/// Every action that lets a reading leave the dashboard — the Diagnosis
/// card's Copy snapshot, the sleep blockers' copy and reveal, a process
/// row's copy and reveal — goes through here, at the moment of the click.
/// Each asks `access()` then and reads the sample the model holds *now*,
/// never a value a view captured when it was built: a report rendered under
/// a grant that has since lapsed is not what gets copied, and a row whose
/// process is no longer in the current sample reveals nothing. The
/// clipboard and the Finder are injectable so a test can catch what is sent.
extension MetricsModel {
    /// What a refused action copies instead of a reading, and shows as the
    /// card's note.
    static let exportRefused = "Not collected: the license doesn’t allow the readings right now."

    /// The result of an export action, for the card's note.
    enum Export: Equatable {
        /// Copied or revealed; the note to show.
        case done(String)
        /// Access does not hold now, or the sample is gone: the clipboard
        /// got `exportRefused`, or nothing was revealed.
        case refused
        /// Access holds, but the process is not in the current sample.
        case gone
    }

    /// The sample, only while access holds now and one is held.
    private func withSample<T>(_ read: () -> T) -> T? {
        guard access(), hasSample else { return nil }
        return read()
    }

    /// The Diagnosis card's Copy snapshot: the report as of now, or the
    /// refusal line, so a click after the grant lapsed exports no reading.
    @discardableResult
    func copyDiagnosticReport() -> Export {
        guard let report = withSample({ diagnosticReport }) else {
            clipboard(Self.exportRefused)
            return .refused
        }
        clipboard(report)
        return .done("Copied the diagnostic snapshot")
    }

    /// The sleep blockers' report, from the current sample.
    @discardableResult
    func copySleepBlockersReport() -> Export {
        guard let report = withSample({ powerAssertionsReport(powerAssertions) }) else {
            clipboard(Self.exportRefused)
            return .refused
        }
        clipboard(report)
        return .done("Copied the sleep blocker report")
    }

    /// One sleep blocker's details, looked up by pid in the current sample.
    @discardableResult
    func copySleepBlockerDetails(pid: pid_t) -> Export {
        guard let group = withSample({ powerAssertions.groups.first { $0.pid == pid } }) else {
            clipboard(Self.exportRefused)
            return .refused
        }
        guard let group else { return .gone }
        let one = PowerAssertionsSnapshot(groups: [group], totalAssertions: group.assertions.count)
        clipboard(powerAssertionsReport(one))
        return .done("Copied \(group.displayName)")
    }

    /// Reveals a sleep blocker's app or binary, from the current sample.
    @discardableResult
    func revealSleepBlocker(pid: pid_t) -> Export {
        guard let group = withSample({ powerAssertions.groups.first { $0.pid == pid } }) else { return .refused }
        guard let group, let url = Self.revealURL(forPath: group.processPath) else { return .gone }
        reveal(url)
        return .done("Revealed \(group.displayName) in Finder")
    }

    /// A process row's PID and path (and its subtree's), from the current tree.
    @discardableResult
    func copyProcessDetails(pid: pid_t) -> Export {
        guard let node = withSample({ Self.node(pid, in: processTree) }) else {
            clipboard(Self.exportRefused)
            return .refused
        }
        guard let node else { return .gone }
        let target = node.processActionTarget
        clipboard(ProcessActions.details(target))
        return .done(target.includesDescendants ? "Copied \(target.items.count) process rows" : "Copied \(target.title)")
    }

    /// Reveals a process's app or binary, from the current tree.
    @discardableResult
    func revealProcess(pid: pid_t) -> Export {
        guard let node = withSample({ Self.node(pid, in: processTree) }) else { return .refused }
        guard let node, let url = Self.revealURL(forPath: node.sample.path) else { return .gone }
        reveal(url)
        return .done("Revealed \(node.processActionTarget.title) in Finder")
    }

    private static func node(_ pid: pid_t, in roots: [ProcessNode]) -> ProcessNode? {
        for root in roots {
            if root.id == pid { return root }
            if let found = node(pid, in: root.children) { return found }
        }
        return nil
    }

    /// The app bundle a path is inside, else the path itself; nil for none.
    static func revealURL(forPath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if let range = path.range(of: ".app/") {
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        return URL(fileURLWithPath: path)
    }
}

/// The real sinks: the general pasteboard and the Finder.
enum ExportSinks {
    static func clipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension MetricsModel.Export {
    /// The card's note after the action.
    var note: String {
        switch self {
        case .done(let text): text
        case .refused: MetricsModel.exportRefused
        case .gone: "No longer in the current sample"
        }
    }
}
