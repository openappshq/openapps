import AppKit
import OpenReactionCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings section listing every app where OpenReaction stays off: the
/// built-in defaults (with their reason, switchable back on but never hidden)
/// and the user's own additions.
struct AppExclusionsSection: View {
    let controller: AppController

    @State private var filter = ""
    @State private var infoCache: [String: InstalledApp] = [:]
    @State private var runningApps: [RunningApp] = []

    private static let filterThreshold = 12

    private var entries: [AppExclusions.Entry] {
        let all = controller.exclusions.entries
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            entry.bundleIdentifier.lowercased().contains(needle)
                || info(for: entry.bundleIdentifier).name.lowercased().contains(needle)
        }
    }

    var body: some View {
        Section {
            if controller.exclusions.entries.count > Self.filterThreshold {
                TextField("Filter apps", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter excluded apps")
            }
            ForEach(entries, id: \.bundleIdentifier) { entry in
                ExclusionRow(entry: entry, app: info(for: entry.bundleIdentifier)) { excluded in
                    controller.setExcluded(excluded, bundleIdentifier: entry.bundleIdentifier)
                } remove: {
                    controller.removeExclusion(entry.bundleIdentifier)
                }
            }
            if entries.isEmpty {
                Text("No apps match “\(filter)”.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textSecondary)
            }
            HStack(spacing: Brand.Space.s8) {
                Button {
                    addFromOpenPanel()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add an app from Applications")
                .accessibilityLabel("Add app")

                Menu {
                    if runningApps.isEmpty {
                        Text("No other apps running")
                    }
                    ForEach(runningApps) { app in
                        Button {
                            controller.addExclusions([app.bundleIdentifier])
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: app.icon)
                            }
                        }
                        .disabled(controller.exclusions.isExcluded(app.bundleIdentifier))
                    }
                } label: {
                    Text("Add Running App")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onAppear(perform: refreshRunningApps)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    refreshRunningApps()
                }
                .accessibilityLabel("Add a running app")

                Spacer()

                Button("Restore Defaults", action: confirmRestoreDefaults)
                    .disabled(!controller.exclusions.hasUserChanges)
            }
        } header: {
            MonoLabel("Apps")
        } footer: {
            Text("OpenReaction stays off in these apps. Defaults cover apps with their own emoji shortcodes and terminals; switch one on to use OpenReaction there anyway.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
        }
    }

    // MARK: - Actions

    private func addFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to exclude"
        panel.message = "OpenReaction will stay off in the apps you choose."
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        controller.addExclusions(identifiers)
    }

    private func refreshRunningApps() {
        let own = Bundle.main.bundleIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let bundleIdentifier = app.bundleIdentifier, bundleIdentifier != own else { return nil }
                return RunningApp(
                    bundleIdentifier: bundleIdentifier,
                    name: app.localizedName ?? bundleIdentifier,
                    icon: app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                )
            }
            .reduce(into: [RunningApp]()) { list, app in
                if !list.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) { list.append(app) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func confirmRestoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore the default app list?"
        alert.informativeText = "Apps you added will be removed from the list, and defaults you switched on will be excluded again."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller.restoreDefaultExclusions()
        }
    }

    private func info(for bundleIdentifier: String) -> InstalledApp {
        if let cached = infoCache[bundleIdentifier] { return cached }
        let resolved = InstalledApp.resolve(bundleIdentifier)
        DispatchQueue.main.async { infoCache[bundleIdentifier] = resolved }
        return resolved
    }
}

private struct RunningApp: Identifiable {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    var id: String { bundleIdentifier }
}

/// Display name and icon for a bundle id, if the app is installed.
private struct InstalledApp {
    let name: String
    let icon: NSImage
    let isInstalled: Bool

    static func resolve(_ bundleIdentifier: String) -> InstalledApp {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return InstalledApp(
                name: bundleIdentifier,
                icon: NSImage(named: NSImage.applicationIconName) ?? NSImage(),
                isInstalled: false
            )
        }
        let info = Bundle(url: url)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return InstalledApp(name: name, icon: NSWorkspace.shared.icon(forFile: url.path), isInstalled: true)
    }
}

private struct ExclusionRow: View {
    let entry: AppExclusions.Entry
    let app: InstalledApp
    let setExcluded: @MainActor (Bool) -> Void
    let remove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(entry.isExcluded ? 1 : 0.6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(Brand.body(14))
                    .foregroundStyle(entry.isExcluded ? Brand.textPrimary : Brand.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Brand.Space.s8) {
                    if let reason = entry.defaultReason {
                        Text("Default")
                            .font(Brand.mono(11, medium: true))
                            .foregroundStyle(entry.isExcluded ? Brand.textSecondary : Brand.textSecondary.opacity(0.6))
                            .padding(.horizontal, Brand.Space.s4)
                            .background(
                                RoundedRectangle(cornerRadius: Brand.Radius.small, style: .continuous)
                                    .fill(Brand.surface)
                            )
                        Text(reason.summary)
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    if !app.isInstalled {
                        Text("Not installed")
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    if !entry.isExcluded {
                        Text("OpenReaction active")
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
            Spacer(minLength: Brand.Space.s8)
            if entry.isDefault {
                Toggle("", isOn: Binding(get: { entry.isExcluded }, set: { setExcluded($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(entry.isExcluded ? "Excluded" : "OpenReaction active")
                    .accessibilityHint("Switch off to use OpenReaction in \(app.name)")
            } else {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(app.name) from the list")
                .accessibilityLabel("Remove \(app.name)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [app.name]
        if let reason = entry.defaultReason {
            parts.append("excluded by default, \(reason.summary.lowercased())")
        } else {
            parts.append("added by you")
        }
        if !app.isInstalled { parts.append("not installed") }
        parts.append(entry.isExcluded ? "OpenReaction off" : "OpenReaction active")
        return parts.joined(separator: ", ")
    }
}
