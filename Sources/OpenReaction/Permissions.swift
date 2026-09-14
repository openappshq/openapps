import AppKit
import ApplicationServices
import CoreGraphics

/// Live Accessibility and Input Monitoring status.
///
/// macOS posts no notification when the user flips these switches, so the
/// monitor polls. Both checks are cheap local TCC lookups.
@MainActor
@Observable
final class PermissionMonitor {
    enum Kind {
        case accessibility
        case inputMonitoring

        var settingsURL: URL {
            switch self {
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            }
        }
    }

    private(set) var accessibility = false
    private(set) var inputMonitoring = false
    /// Settings was opened for this permission and it is not granted yet.
    private(set) var awaiting: Set<Kind> = []

    var allGranted: Bool { accessibility && inputMonitoring }

    /// Called after every poll, so callers can retry work that needs the permissions.
    @ObservationIgnored var onPoll: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        if accessibility != self.accessibility { self.accessibility = accessibility }
        if inputMonitoring != self.inputMonitoring { self.inputMonitoring = inputMonitoring }
        if accessibility { awaiting.remove(.accessibility) }
        if inputMonitoring { awaiting.remove(.inputMonitoring) }
        onPoll?()
    }

    /// Registers OpenReaction in the permission list (macOS only lists apps
    /// that asked) and opens the matching System Settings pane.
    func openSettings(for kind: Kind) {
        switch kind {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        awaiting.insert(kind)
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
