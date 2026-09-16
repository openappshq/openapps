import AppKit
import OpenNotesCore
import ServiceManagement

/// The system's login-item registration behind `LoginItem`, so the debug
/// preview harness can stand in something that registers nothing.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct MainAppLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// "Open at login" through `SMAppService.mainApp`. A packaged app turns it
/// on once, on the first launch of a fresh install (`applyDefaultIfNeeded`,
/// `FreshInstallDefault`); the Settings toggle decides from then on. The
/// status is always re-read from the system, since the user can remove the
/// item in System Settings at any time.
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any LoginItemService
    /// Created at launch, before this launch writes any preferences.
    @ObservationIgnored private let launchDefault: FreshInstallDefault

    init(flags: any FlagStore = UserDefaults.standard, service: any LoginItemService = MainAppLoginItemService()) {
        self.service = service
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
        let current = service.status
        if current != status { status = current }
    }

    /// The user's choice in Settings. Recorded first, so the default can
    /// never undo it — also when storage has not answered yet and the
    /// default is still pending.
    func setOn(_ on: Bool) {
        launchDefault.markSuperseded()
        register(on)
    }

    /// The default, once: registers when the install is demonstrably fresh
    /// (no earlier preferences, and `storageIsFresh` — in a source build
    /// always true, there being no record store; nil while unknown, which
    /// waits). Once decided, the system is not asked again. A registration
    /// macOS refuses is reported in Settings like any other.
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
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        service.openSystemSettings()
    }
}
