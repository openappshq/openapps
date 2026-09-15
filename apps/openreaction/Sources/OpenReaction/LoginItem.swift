import AppKit
import OpenReactionCore
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp`. Official builds turn it
/// on once, on the first launch (`applyDefaultIfNeeded`); the Settings
/// toggle decides from then on. The status is always re-read from the
/// system, since the user can remove the item in System Settings at any
/// time.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?
    @ObservationIgnored private let flags: any FlagStore

    init(flags: any FlagStore = UserDefaults.standard) {
        self.flags = flags
        refresh()
    }

    /// Only a real `.app` bundle can be registered; `swift run` builds cannot.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Registered, including when macOS still waits for the user's approval.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    /// The user's choice in Settings or onboarding.
    func setOn(_ on: Bool) {
        register(on)
    }

    /// The default, once: registers on the first launch that finds the item
    /// unregistered. A registration macOS refuses is reported in Settings
    /// like any other.
    func applyDefaultIfNeeded() {
        guard isAvailable else { return }
        refresh()
        guard LoginItemDefault.shouldRegister(store: flags, isRegistered: isOn) else { return }
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
