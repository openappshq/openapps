#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
import SwiftUI

/// Settings → Updates (RELEASES.md, "In-app updater"). The check toggle
/// goes through `Updates`, which records the choice before the switch so
/// the fresh-install default can never undo it.
struct UpdatesSection: View {
    let updates: Updates

    private var updater: Updater { updates.updater }

    var body: some View {
        Section {
            if updater.location != .updatable {
                note("Move OpenReaction to Applications to enable updates.")
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
                        note("An update could not be completed and the previous version was kept at \(backup.path). If OpenReaction works, remove it.")
                        Spacer()
                        Button("Remove Previous Copy") { updater.discardPreservedBackup() }
                    }
                }
            }
        } header: {
            MonoLabel("Updates")
        } footer: {
            Text("Checking is on for new installs: once a day OpenReaction looks for a new version and tells you when there is one. Installing is your call, unless \"Download and install automatically\" is on too; then it installs when you quit. Turning a switch off cancels anything it started. A check only downloads the update list from openapps.space and sends nothing about you or this Mac. Installed with Homebrew? `brew upgrade --cask openreaction` updates it too.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .idle, .upToDate:
            HStack {
                Text(updater.phase == .upToDate ? "OpenReaction is up to date." : lastCheckText)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                Spacer()
                Button("Check Now") { updater.checkNow() }
            }
        case .checking:
            HStack {
                Text("Checking…").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .available(let item):
            HStack {
                Text("OpenReaction \(item.version.description) is available.").font(Brand.body(13))
                Spacer()
                Button("Install and Restart") { updater.installAvailable() }
            }
        case .downloading(let item):
            HStack {
                Text("Downloading OpenReaction \(item.version.description)…").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .staged(let staged):
            HStack {
                Text("OpenReaction \(staged.item.version.description) is ready and installs when you quit.").font(Brand.body(13))
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
