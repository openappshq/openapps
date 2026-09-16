import AppKit
import Foundation
#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
#endif

/// Hooks for scripts/update-e2e.sh, compiled only into update-test builds
/// (`OPENNOTES_UPDATE_TEST=1`, which also gives them their own bundle
/// identifier; `UpdateTesting.isCompiledIn` is declared beside the launch
/// path in AppDelegate.swift). Release builds contain none of it: every
/// member below is a constant or an empty function there, and
/// scripts/verify-release.sh refuses a binary that mentions these variables.
///
/// An update-test build never registers a login item, never opens the
/// setup guide and keeps its notes in its own Application Support folder
/// (`Preferences.defaultFolder`), never the user's: it is a throwaway copy
/// that runs on any Mac and must leave nothing behind but what the test
/// removes.
extension UpdateTesting {
    #if OPENNOTES_UPDATE_TESTING
    /// `quit`: quit once an update is staged (install on quit).
    /// `restart`: take "Update ready — Restart" once an update is staged.
    /// `revoke-during-download`: turn "install automatically" off as soon as
    /// the download starts, then quit.
    /// `revoke-after-staged`: turn it off once the update is staged, then quit.
    /// `quit-after-check`: quit once a check has finished, whatever it found.
    private static let action = ProcessInfo.processInfo.environment["OPENNOTES_UPDATE_TEST_ACTION"]

    @MainActor
    static func updateIsReady(installNow: @escaping @MainActor () -> Void, version: String) {
        report("ready \(version)")
        switch action {
        case "quit":
            Updater.terminateFromTheRunLoop(after: 1)
        case "restart":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { installNow() }
        default:
            break
        }
    }

    #if OPENAPPS_OFFICIAL
    @MainActor
    static func phaseChanged(_ phase: Updater.Phase, revoke: @escaping @MainActor () -> Void) {
        switch phase {
        case .downloading: report("downloading")
        case .staged: report("staged")
        case .available(let item): report("available \(item.version.description)")
        case .upToDate: report("up-to-date")
        case .idle: report("idle")
        default: break
        }
        switch (action, phase) {
        case ("revoke-during-download", .downloading):
            DispatchQueue.main.async {
                revoke()
                report("revoked-during-download")
                Updater.terminateFromTheRunLoop(after: 1)
            }
        case ("revoke-after-staged", .staged):
            DispatchQueue.main.async {
                revoke()
                report("revoked-after-staged")
                Updater.terminateFromTheRunLoop(after: 1)
            }
        default:
            break
        }
    }
    #endif

    @MainActor
    static func cycleFinished(error: (any Error)?) {
        report("cycle-finished \(error.map { $0.localizedDescription } ?? "ok")")
        if action == "quit-after-check" {
            Updater.terminateFromTheRunLoop(after: 1)
        }
    }

    static func quitFinished(outcome: String, reopening: Bool) {
        report("quit \(outcome) reopening=\(reopening)")
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("opennotes-update-test: \(line)\n".utf8))
    }
    #else
    @MainActor
    static func updateIsReady(installNow: @escaping @MainActor () -> Void, version: String) {}
    @MainActor
    static func cycleFinished(error: (any Error)?) {}
    static func quitFinished(outcome: String, reopening: Bool) {}
    #if OPENAPPS_OFFICIAL
    @MainActor
    static func phaseChanged(_ phase: Updater.Phase, revoke: @escaping @MainActor () -> Void) {}
    #endif
    #endif
}
