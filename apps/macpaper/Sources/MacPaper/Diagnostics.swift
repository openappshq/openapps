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
            licensing: Licensing.diagnosticsLine(model.license),
            displays: model.displays,
            width: preferences.width,
            hideInFullscreen: preferences.hideInFullscreen,
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

    static func text(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter, keeper: DesktopKeeper? = nil) -> String {
        var text = snapshot(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys).text()
        text += "\nKeep it applied: \(preferences.keepApplied ? "on" : "off") · last check \(keeper?.lastReport ?? "n/a")"
        text += "\nPer-Space displays: \(model.appliedState.perSpaceDisplayIDs.sorted().map(String.init).joined(separator: ", "))"
        text += "\nFallback stills: \(model.appliedState.fallbackDisplayIDs.sorted().map(String.init).joined(separator: ", "))"
        text += "\nClock: \(preferences.clockStyle.rawValue) · \(preferences.clockPosition.rawValue) · \(preferences.clockSize.rawValue)"
        text += "\nNever show: \(model.blockedCount)"
        return text
    }
}
