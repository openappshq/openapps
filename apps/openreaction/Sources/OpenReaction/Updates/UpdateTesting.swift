import AppKit
import Foundation

/// Hooks for scripts/update-e2e.sh, compiled only into update-test builds
/// (`OPENREACTION_UPDATE_TEST=1`, which also gives them their own bundle
/// identifier). Release builds contain none of it: every member below is a
/// constant or an empty function there, and scripts/verify-release.sh
/// refuses a binary that mentions these variables.
enum UpdateTesting {
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
    /// `quit`: quit once an update is ready (install on quit).
    /// `restart`: take "Update ready — Restart" once an update is ready.
    private static let action = ProcessInfo.processInfo.environment["OPENREACTION_UPDATE_TEST_ACTION"]

    @MainActor
    static func updateIsReady(installNow: @escaping () -> Void) {
        report("ready")
        switch action {
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        case "restart":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { installNow() }
        default:
            break
        }
    }

    static func cycleFinished(error: (any Error)?) {
        report("cycle-finished \(error.map { ($0 as NSError).domain + " " + String(($0 as NSError).code) + " " + $0.localizedDescription } ?? "ok")")
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("openreaction-update-test: \(line)\n".utf8))
    }
    #else
    @MainActor
    static func updateIsReady(installNow: @escaping () -> Void) {}
    static func cycleFinished(error: (any Error)?) {}
    #endif
}
