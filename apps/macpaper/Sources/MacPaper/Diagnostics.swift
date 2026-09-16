import Foundation
import MacPaperCore

/// Plain-text state for bug reports, from the live objects. Only copied on
/// request and only to the pasteboard.
enum Diagnostics {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static func snapshot(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: versionString,
            loginStatus: loginItem.statusDescription,
            licensing: Licensing.flavourDescription,
            displays: model.displays,
            panelSettings: preferences.panelSettings,
            hostDisplay: preferences.hostDisplay,
            direction: preferences.direction,
            width: preferences.width,
            hotkey: preferences.hotkey,
            hotkeyProblem: hotkeys.problem,
            shuffle: preferences.shuffleInterval,
            favoritesOnly: preferences.favoritesOnly,
            sameOnAllDisplays: preferences.sameOnAllDisplays,
            favoritesCount: model.favoriteList.count,
            applied: model.appliedState.byDisplay,
            lastApplied: model.appliedState.lastApplied
        )
    }

    static func text(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter) -> String {
        snapshot(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys).text()
    }
}
