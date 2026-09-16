import Foundation
import OpenNotesCore

/// Plain-text state for bug reports, from the live objects. Only copied on
/// request and only to the pasteboard; never a note's text.
enum Diagnostics {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func snapshot(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter, deck: DeckHost?) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: versionString,
            macOSVersion: macOSVersion,
            loginStatus: loginItem.statusDescription,
            // The flavour and where the license stands (never the key).
            licensing: Licensing.diagnosticsLine(model.license),
            readOnly: model.readOnly,
            side: preferences.side,
            display: preferences.display,
            hotkey: preferences.hotkey,
            hotkeyProblem: hotkeys.problem,
            folder: preferences.folderDisplayPath,
            folderIsMissing: model.store.folderIsMissing,
            watching: model.watcher.isWatching,
            activeCount: model.active.count,
            archivedCount: model.archived.count,
            unsavedCount: model.store.notes.keys.filter { model.store.hasUnsavedChanges($0) }.count,
            defaultFont: preferences.defaultFontDescription,
            defaultColor: preferences.newNoteColor.title,
            autoArchiveDays: preferences.autoArchiveDays,
            deckState: deck?.stateDescription ?? "hidden",
            hostedDisplays: deck?.hostedDisplayNames ?? []
        )
    }

    static func text(model: AppModel, preferences: Preferences, loginItem: LoginItem, hotkeys: HotkeyCenter, deck: DeckHost?) -> String {
        snapshot(model: model, preferences: preferences, loginItem: loginItem, hotkeys: hotkeys, deck: deck).text()
    }
}
