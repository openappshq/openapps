import AppKit
import Foundation

/// Opening Activity Monitor is the one sleep-blocker action that exposes no
/// reading; copying and revealing go through `MetricsModel`'s gated exports.
enum PowerAssertionActions {
    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
