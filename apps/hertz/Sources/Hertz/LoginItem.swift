import AppKit
import HertzCore
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp`. A packaged app turns it
/// on once, on the first launch of a fresh install (`applyDefaultIfNeeded`,
/// `FreshInstallDefault`); the Settings toggle decides from then on. The
/// status is always re-read from the system, since the user can remove the
/// item in System Settings at any time.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?
    /// Created at launch, before this launch writes any preferences.
    @ObservationIgnored private let launchDefault: FreshInstallDefault

    init(flags: any FlagStore = UserDefaults.standard) {
        launchDefault = .loginItem(store: flags)
        refresh()
    }

    /// Only a real `.app` bundle can be registered; `swift run` builds cannot.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Registered, including when macOS still waits for the user's approval.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    /// The status in words, for Copy Diagnostics.
    var statusDescription: String {
        switch status {
        case .enabled: "on"
        case .requiresApproval: "waiting for approval in Login Items"
        case .notRegistered: "off"
        case .notFound: "not found"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    /// The user's choice in Settings or the setup guide. Recorded first, so
    /// the default can never undo it — also when storage has not answered
    /// yet and the default is still pending.
    func setOn(_ on: Bool) {
        launchDefault.markSuperseded()
        register(on)
    }

    /// The default, once: registers when the install is demonstrably fresh
    /// (no earlier preferences, and `storageIsFresh` — the license and trial
    /// records positively absent; nil while unknown, which waits). Once
    /// decided, the system is not asked again. A registration macOS refuses
    /// is reported in Settings like any other.
    func applyDefaultIfNeeded(storageIsFresh: Bool?) {
        guard isAvailable, storageIsFresh != nil, !launchDefault.isDecided else { return }
        refresh()
        guard launchDefault.shouldTurnOn(isOn: isOn, storageIsFresh: storageIsFresh) else { return }
        register(true)
    }

    private func register(_ on: Bool) {
        errorMessage = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
