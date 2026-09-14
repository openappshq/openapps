import AppKit
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp`. Off until the user turns it
/// on; the status is always re-read from the system, since the user can remove
/// the item in System Settings at any time.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?

    init() {
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

    func setOn(_ on: Bool) {
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
