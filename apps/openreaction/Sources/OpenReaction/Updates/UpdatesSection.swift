#if OPENAPPS_OFFICIAL
import OpenAppsUpdater
import SwiftUI

/// Settings → Updates (RELEASES.md, "In-app updater").
struct UpdatesSection: View {
    let updates: Updater

    var body: some View {
        Section {
            if updates.location != .updatable {
                note("Move OpenReaction to Applications to enable updates.")
            } else {
                Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.setChecksAutomatically($0) })) {
                    Text("Check for updates automatically").font(Brand.body(14))
                }
                Toggle(isOn: Binding(get: { updates.installsAutomatically }, set: { updates.setInstallsAutomatically($0) })) {
                    Text("Download and install automatically").font(Brand.body(14))
                }
                .disabled(!updates.checksAutomatically)
                statusRow
                if let backup = updates.preservedBackup {
                    HStack(alignment: .top) {
                        note("An update could not be completed and the previous version was kept at \(backup.path). If OpenReaction works, remove it.")
                        Spacer()
                        Button("Remove Previous Copy") { updates.discardPreservedBackup() }
                    }
                }
            }
        } header: {
            MonoLabel("Updates")
        } footer: {
            Text("Both are off by default, so OpenReaction only looks for updates when you click Check Now. Turned on, it checks once a day and installs updates when you quit; turning them off again cancels anything it downloaded. A check only downloads the update list from openapps.space and sends nothing about you or this Mac. Installed with Homebrew? `brew upgrade --cask openreaction` updates it too.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updates.phase {
        case .idle, .upToDate:
            HStack {
                Text(updates.phase == .upToDate ? "OpenReaction is up to date." : lastCheckText)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                Spacer()
                Button("Check Now") { updates.checkNow() }
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
                Button("Install and Restart") { updates.installAvailable() }
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
                Button("Restart to Update") { updates.restartToUpdate() }
            }
        case .failed(let message):
            HStack(alignment: .top) {
                note("Update failed: \(message)")
                Spacer()
                Button("Try Again") { updates.checkNow() }
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "Never checked" }
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
