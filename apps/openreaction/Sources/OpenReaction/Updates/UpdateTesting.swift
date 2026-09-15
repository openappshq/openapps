import AppKit
import Foundation
#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
#endif

/// Hooks for scripts/update-e2e.sh, compiled only into update-test builds
/// (`OPENREACTION_UPDATE_TEST=1`, which also gives them their own bundle
/// identifier). Release builds contain none of it: every member below is a
/// constant or an empty function there, and scripts/verify-release.sh
/// refuses a binary that mentions these variables.
enum UpdateTesting {
    #if OPENREACTION_UPDATE_TESTING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif

    /// Update-test builds never install the keyboard event tap or ask for
    /// permissions, so running them on a shared Mac is harmless. Opt back in
    /// with `OPENREACTION_DISABLE_TAP=0`.
    static var disablesEventTap: Bool {
        #if OPENREACTION_UPDATE_TESTING
        ProcessInfo.processInfo.environment["OPENREACTION_DISABLE_TAP"] != "0"
        #else
        false
        #endif
    }

    #if OPENREACTION_UPDATE_TESTING
    /// `quit`: quit once an update is staged (install on quit).
    /// `restart`: take "Update ready — Restart" once an update is staged.
    /// `revoke-during-download`: turn "install automatically" off as soon as
    /// the download starts, then quit.
    /// `revoke-after-staged`: turn it off once the update is staged, then quit.
    private static let action = ProcessInfo.processInfo.environment["OPENREACTION_UPDATE_TEST_ACTION"]

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

    static func cycleFinished(error: (any Error)?) {
        report("cycle-finished \(error.map { $0.localizedDescription } ?? "ok")")
    }

    static func quitFinished(outcome: String, reopening: Bool) {
        report("quit \(outcome) reopening=\(reopening)")
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("openreaction-update-test: \(line)\n".utf8))
    }
    #else
    @MainActor
    static func updateIsReady(installNow: @escaping @MainActor () -> Void, version: String) {}
    static func cycleFinished(error: (any Error)?) {}
    static func quitFinished(outcome: String, reopening: Bool) {}
    #if OPENAPPS_OFFICIAL
    @MainActor
    static func phaseChanged(_ phase: Updater.Phase, revoke: @escaping @MainActor () -> Void) {}
    #endif
    #endif
}
