import AppKit
import ApplicationServices
import CoreGraphics
import OpenReactionCore
import Security

/// Live answers from TCC. Both calls are cheap local lookups.
struct SystemPermissionProvider: PermissionProvider {
    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }
}

extension PermissionKind {
    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var settingsURL: URL {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        }
    }

    /// Service name understood by `tccutil`.
    var tccService: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "ListenEvent"
        }
    }
}

/// Identifies this exact build the way TCC does: the code directory hash of
/// the running signature. Unsigned builds fall back to version and executable
/// modification date.
enum CodeIdentity {
    static func current() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dictionary = info as? [String: Any],
           let unique = dictionary[kSecCodeInfoUnique as String] as? Data {
            return unique.map { String(format: "%02x", $0) }.joined()
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let modified = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return "unsigned-\(version)-\(modified)"
    }
}

/// Snapshot of `PermissionFlow` for SwiftUI. Published only when it changes,
/// so a once-a-second poll does not re-render anything.
struct PermissionSnapshot: Equatable {
    var statuses: [PermissionKind: PermissionStatus] = [:]
    var reportedGranted: Set<PermissionKind> = []
    var isTapFailing = false
    var isComplete = false

    func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .missing }
}

/// Owns the permission state machine and decides how often to look at TCC.
///
/// macOS posts no notification when the user flips these switches, so the
/// monitor polls:
/// - every second while onboarding or the System Settings guide is visible,
///   so granting feels immediate;
/// - every 15 seconds otherwise, so a revoked permission stops the tap soon;
/// - immediately whenever OpenReaction becomes active.
@MainActor
@Observable
final class PermissionMonitor {
    private(set) var snapshot = PermissionSnapshot()
    private(set) var resetInProgress: PermissionKind?
    private(set) var lastError: String?

    var allGranted: Bool { snapshot.reportedGranted.count == PermissionKind.allCases.count }
    func status(_ kind: PermissionKind) -> PermissionStatus { snapshot.status(kind) }

    /// Called after every poll, so callers can retry work that needs the permissions.
    @ObservationIgnored var onPoll: (() -> Void)?

    @ObservationIgnored private var flow: PermissionFlow
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fastPollingReasons: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let fastInterval: TimeInterval = 1
    static let backgroundInterval: TimeInterval = 15
    private static let memoryKey = "permissionFlow"

    @ObservationIgnored private let defaults: UserDefaults

    /// `provider` and `defaults` are TCC and the app's own preferences,
    /// except in the debug preview harness (a stub and a throwaway suite).
    init(provider: any PermissionProvider = SystemPermissionProvider(), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let memory = defaults.data(forKey: Self.memoryKey)
            .flatMap { try? JSONDecoder().decode(PermissionFlow.Memory.self, from: $0) }
        flow = PermissionFlow(
            provider: provider,
            codeIdentity: CodeIdentity.current(),
            memory: memory ?? PermissionFlow.Memory()
        )
        publish()
    }

    var codeIdentity: String { flow.codeIdentity }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        reschedule()
        refresh()
    }

    /// Poll every second while any reason is active.
    func setFastPolling(_ enabled: Bool, reason: String) {
        let changed = enabled ? fastPollingReasons.insert(reason).inserted : fastPollingReasons.remove(reason) != nil
        guard changed else { return }
        reschedule()
        if enabled { refresh() }
    }

    func refresh() {
        flow.refresh()
        commit()
        onPoll?()
    }

    func onboardingStep(hasStarted: Bool, practiceFinished: Bool) -> OnboardingStep {
        _ = snapshot // Register the observation dependency.
        return flow.onboardingStep(hasStarted: hasStarted, practiceFinished: practiceFinished)
    }

    // MARK: - Tap feedback

    func recordTap(running: Bool) {
        flow.recordTap(running: running)
        commit()
    }

    func willRelaunch() {
        flow.willRelaunch()
        commit()
    }

    func relaunchFailed() {
        flow.relaunchFailed()
        commit()
    }

    // MARK: - Actions

    /// Registers OpenReaction in the permission list (macOS only lists apps
    /// that asked) and opens the matching System Settings pane.
    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            // String key: the SDK's kAXTrustedCheckOptionPrompt global is not concurrency-safe.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        flow.didRequest(kind)
        commit()
        NSWorkspace.shared.open(kind.settingsURL)
    }

    var canReset: Bool { Bundle.main.bundleIdentifier != nil }

    /// Removes OpenReaction's own TCC entry for `kind` with `tccutil`, then
    /// asks again so a fresh entry matching this build appears in the list.
    func reset(_ kind: PermissionKind) async {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, resetInProgress == nil else { return }
        resetInProgress = kind
        lastError = nil
        let result = await Self.runTCCReset(service: kind.tccService, bundleIdentifier: bundleIdentifier)
        resetInProgress = nil
        if let result {
            lastError = result
            return
        }
        flow.didReset(kind)
        commit()
        onPoll?()
        request(kind)
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func clearError() {
        lastError = nil
    }

    /// Runs `/usr/bin/tccutil reset <service> <bundle id>` directly, without a
    /// shell. Returns an error message, or nil on success.
    private nonisolated static func runTCCReset(service: String, bundleIdentifier: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleIdentifier]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return "Couldn't run tccutil: \(error.localizedDescription)"
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return output.isEmpty ? "tccutil failed (\(process.terminationStatus))." : output
            }
            return nil
        }.value
    }

    // MARK: - Private

    private func reschedule() {
        timer?.invalidate()
        let interval = fastPollingReasons.isEmpty ? Self.backgroundInterval : Self.fastInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func commit() {
        publish()
        if let data = try? JSONEncoder().encode(flow.memory) {
            defaults.set(data, forKey: Self.memoryKey)
        }
    }

    private func publish() {
        var next = PermissionSnapshot()
        for kind in PermissionKind.allCases {
            next.statuses[kind] = flow.status(of: kind)
            if flow.isReportedGranted(kind) { next.reportedGranted.insert(kind) }
        }
        next.isTapFailing = flow.isTapFailing
        next.isComplete = flow.isComplete
        if next != snapshot { snapshot = next }
    }
}
