#if OPENAPPS_OFFICIAL
import OpenReactionCore
import SwiftUI

/// Settings → Updates (RELEASES.md, "In-app updater").
struct UpdatesSection: View {
    let updates: UpdateController

    var body: some View {
        Section {
            if updates.location != .updatable {
                note("Move OpenReaction to Applications to enable updates.")
            } else {
                Toggle(isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) })) {
                    Text("Check for updates automatically").font(Brand.body(14))
                }
                .disabled(!updates.isAvailable)
                Toggle(isOn: Binding(get: { updates.automaticDownloads }, set: { updates.setAutomaticDownloads($0) })) {
                    Text("Download and install automatically").font(Brand.body(14))
                }
                .disabled(!updates.isAvailable || !updates.automaticChecks)
                if let version = updates.readyVersion {
                    HStack {
                        Text("OpenReaction \(version) is downloaded and installs when you quit, whatever the settings above.").font(Brand.body(13))
                        Spacer()
                        Button("Restart to Update") { updates.restartToUpdate() }
                    }
                }
                HStack {
                    Text(lastCheckText)
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer()
                    Button("Check Now") { updates.checkNow() }
                        .disabled(!updates.canCheckNow)
                }
            }
        } header: {
            MonoLabel("Updates")
        } footer: {
            Text("Both are off by default, so OpenReaction only looks for updates when you click Check Now. Turned on, it checks once a day and installs updates when you quit. A check only downloads the update list from openapps.space and sends nothing about you or this Mac. Installed with Homebrew? `brew upgrade --cask openreaction` updates it too.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
