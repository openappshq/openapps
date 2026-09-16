import OpenNotesCore
#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
#endif
import SwiftUI

/// Settings → Updates (RELEASES.md, "In-app updater"). An official build
/// shows the two toggles, the status and "Check Now"; the check toggle goes
/// through `Updates`, which records the choice before the switch so the
/// fresh-install default can never undo it. A build from source has no
/// updater and says so; both show the version.
struct UpdatesSection: View {
    #if OPENAPPS_OFFICIAL
    let updates: Updates?
    #endif

    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(Diagnostics.versionString).font(Brand.mono(12)).textSelection(.enabled)
            }
            #if OPENAPPS_OFFICIAL
            if let updates {
                UpdaterControls(updates: updates)
            } else {
                note("This build has no update feed configured, so it cannot check for updates.")
            }
            #else
            note("Builds from source don’t include app updates. The official build, installed with Homebrew, checks for updates automatically and installs them only when you say so.")
            #endif
        } header: {
            MonoLabel("Updates")
        } footer: {
            #if OPENAPPS_OFFICIAL
            Text("Checking is on for new installs: once a day OpenNotes looks for a new version and tells you when there is one. Installing is your call, unless \"Download and install automatically\" is on too; then it installs when you quit. Turning a switch off cancels anything it started. A check only downloads the update list from openapps.space and sends nothing about you or this Mac. Installed with Homebrew? `\(Updating.upgradeCommand)` updates it too.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Brand.body(12))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if OPENAPPS_OFFICIAL
/// The toggles and the status row, against the live updater.
private struct UpdaterControls: View {
    let updates: Updates

    private var updater: Updater { updates.updater }

    var body: some View {
        if updater.location != .updatable {
            note("Move OpenNotes to Applications to enable updates.")
        } else {
            Toggle(isOn: Binding(get: { updater.checksAutomatically }, set: { updates.setChecksAutomatically($0) })) {
                Text("Check for updates automatically").font(Brand.body(14))
            }
            Toggle(isOn: Binding(get: { updater.installsAutomatically }, set: { updater.setInstallsAutomatically($0) })) {
                Text("Download and install automatically").font(Brand.body(14))
            }
            .disabled(!updater.checksAutomatically)
            statusRow
            if let backup = updater.preservedBackup {
                HStack(alignment: .top) {
                    note("An update could not be completed and the previous version was kept at \(backup.path). If OpenNotes works, remove it.")
                    Spacer()
                    Button("Remove Previous Copy") { updater.discardPreservedBackup() }
                }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .idle, .upToDate:
            HStack {
                note(updater.phase == .upToDate ? "OpenNotes is up to date." : lastCheckText)
                Spacer()
                Button("Check Now") { updater.checkNow() }
            }
        case .checking:
            HStack {
                note("Checking…")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .available(let item):
            HStack {
                Text("OpenNotes \(item.version.description) is available.").font(Brand.body(13))
                Spacer()
                Button("Install and Restart") { updater.installAvailable() }
            }
        case .downloading(let item):
            HStack {
                note("Downloading OpenNotes \(item.version.description)…")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .staged(let staged):
            HStack {
                Text("OpenNotes \(staged.item.version.description) is ready and installs when you quit.").font(Brand.body(13))
                Spacer()
                Button("Restart to Update") { updater.restartToUpdate() }
            }
        case .failed(let message):
            HStack(alignment: .top) {
                note("Update failed: \(message)")
                Spacer()
                Button("Try Again") { updater.checkNow() }
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return "Never checked" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Brand.body(12))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
