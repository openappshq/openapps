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
    @State private var apps = InstalledAppStore()
    @State private var runningApps: [RunningApp] = []

    private static let filterThreshold = 12

    private var entries: [AppExclusions.Entry] {
        let all = controller.exclusions.entries
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            entry.bundleIdentifier.lowercased().contains(needle)
                || apps.info(for: entry.bundleIdentifier).name.lowercased().contains(needle)
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
                ExclusionRow(entry: entry, app: apps.info(for: entry.bundleIdentifier)) { active in
                    controller.setExcluded(!active, bundleIdentifier: entry.bundleIdentifier)
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
            Text("OpenReaction stays off in these apps. Defaults cover apps with their own emoji shortcodes and terminals. The switch means “OpenReaction on in this app”: turn it on to use OpenReaction there anyway.")
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
        addApps(at: panel.urls)
    }

    /// Common add path: reads each bundle id, skips OpenReaction itself and
    /// bundles without a readable id, and says which were skipped.
    private func addApps(at urls: [URL]) {
        var identifiers: [String] = []
        var unreadable: [String] = []
        var ownApp = false
        for url in urls {
            let name = FileManager.default.displayName(atPath: url.path)
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier, !bundleIdentifier.isEmpty else {
                unreadable.append(name)
                continue
            }
            if bundleIdentifier == Bundle.main.bundleIdentifier {
                ownApp = true
                continue
            }
            identifiers.append(bundleIdentifier)
        }
        controller.addExclusions(identifiers)

        var notes: [String] = []
        if ownApp {
            notes.append("OpenReaction can’t exclude itself: the setup guide’s practice field needs it to work here.")
        }
        if !unreadable.isEmpty {
            notes.append("Skipped (no bundle identifier): " + unreadable.joined(separator: ", "))
        }
        guard !notes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = identifiers.isEmpty ? "No apps were added" : "Some apps were not added"
        alert.informativeText = notes.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        alert.informativeText = "Apps you added will be removed from the list, and defaults you switched on will be switched off again."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller.restoreDefaultExclusions()
        }
    }

}

/// Settings section for the typed-replacement fallback: it is on everywhere by
/// default, so this lists only the apps the user has switched it off in, and
/// lets them add more or switch one back on.
struct TypedReplacementSection: View {
    let controller: AppController

    @State private var apps = InstalledAppStore()
    @State private var runningApps: [RunningApp] = []

    private var disabled: [String] { controller.typedReplacement.disabledBundleIdentifiers }

    var body: some View {
        Section {
            ForEach(disabled, id: \.self) { bundleIdentifier in
                let app = apps.info(for: bundleIdentifier)
                HStack(spacing: Brand.Space.s12) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(Brand.body(14))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if app.isInstalled == false {
                            Text("Not installed")
                                .font(Brand.body(12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                    }
                    Spacer(minLength: Brand.Space.s8)
                    Button {
                        controller.setTypedReplacement(true, bundleIdentifier: bundleIdentifier)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Turn typed replacement back on in \(app.name)")
                    .accessibilityLabel("Turn typed replacement on in \(app.name)")
                }
                .padding(.vertical, 2)
            }
            if disabled.isEmpty {
                Text("Typed replacement is on in every app.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textSecondary)
            }
            HStack(spacing: Brand.Space.s8) {
                Button(action: addFromOpenPanel) {
                    Image(systemName: "plus")
                }
                .help("Turn typed replacement off in an app from Applications")
                .accessibilityLabel("Turn typed replacement off in an app")

                Menu {
                    if runningApps.isEmpty {
                        Text("No other apps running")
                    }
                    ForEach(runningApps) { app in
                        Button {
                            controller.disableTypedReplacement([app.bundleIdentifier])
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                        .disabled(!controller.typedReplacement.isEnabled(app.bundleIdentifier))
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
                .accessibilityLabel("Turn typed replacement off in a running app")

                Spacer()

                Button("Restore Defaults") { controller.restoreDefaultTypedReplacement() }
                    .disabled(!controller.typedReplacement.hasUserChanges)
            }
        } header: {
            MonoLabel("Typed replacement")
        } footer: {
            Text("Some apps — Chrome and other Chromium or Electron apps — don’t let OpenReaction read the field back to confirm the caret. There, OpenReaction falls back to deleting what it saw you type and typing the emoji, trusting it is still at the caret. Turn it off for an app to keep OpenReaction from typing into fields it can’t read.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
        }
    }

    private func addFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps"
        panel.message = "OpenReaction will not use typed replacement in the apps you choose."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let identifiers = panel.urls.compactMap { url -> String? in
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier, !bundleIdentifier.isEmpty,
                  bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            return bundleIdentifier
        }
        controller.disableTypedReplacement(identifiers)
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
}

private struct RunningApp: Identifiable {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    var id: String { bundleIdentifier }
}

/// Display name and icon for a bundle id.
private struct InstalledApp: @unchecked Sendable {
    let name: String
    let icon: NSImage
    /// nil while the lookup is still running.
    let isInstalled: Bool?

    static func placeholder(_ bundleIdentifier: String) -> InstalledApp {
        InstalledApp(name: bundleIdentifier, icon: Self.genericIcon, isInstalled: nil)
    }

    static let genericIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()

    /// Launch Services and icon lookups; runs off the main thread.
    static func resolve(_ bundleIdentifier: String) -> InstalledApp {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return InstalledApp(name: bundleIdentifier, icon: genericIcon, isInstalled: false)
        }
        let info = Bundle(url: url)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return InstalledApp(name: name, icon: NSWorkspace.shared.icon(forFile: url.path), isInstalled: true)
    }
}

/// Resolves app names and icons off the render path. `info(for:)` returns a
/// placeholder at once, starts one lookup per bundle id, and publishes the
/// result so rows re-render when it lands.
@MainActor
@Observable
private final class InstalledAppStore {
    private var cache: [String: InstalledApp] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let queue = DispatchQueue(label: "com.openappshq.openreaction.app-info", qos: .userInitiated)

    func info(for bundleIdentifier: String) -> InstalledApp {
        if let cached = cache[bundleIdentifier] { return cached }
        if inFlight.insert(bundleIdentifier).inserted {
            queue.async {
                let resolved = InstalledApp.resolve(bundleIdentifier)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.cache[bundleIdentifier] = resolved
                        self.inFlight.remove(bundleIdentifier)
                    }
                }
            }
        }
        return .placeholder(bundleIdentifier)
    }
}

private struct ExclusionRow: View {
    let entry: AppExclusions.Entry
    let app: InstalledApp
    /// Called with the switch's new value: true means OpenReaction is on here.
    let setActive: @MainActor (Bool) -> Void
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
                    if app.isInstalled == false {
                        Text("Not installed")
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    if !entry.isExcluded {
                        Text("OpenReaction on")
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
            Spacer(minLength: Brand.Space.s8)
            if entry.isDefault {
                // On means OpenReaction is on in this app; off means excluded.
                Toggle("", isOn: Binding(get: { !entry.isExcluded }, set: { setActive($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("OpenReaction in \(app.name)")
                    .accessibilityValue(entry.isExcluded ? "Off" : "On")
                    .accessibilityHint(entry.isExcluded
                        ? "Switch on to use OpenReaction in \(app.name)"
                        : "Switch off to keep OpenReaction out of \(app.name)")
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
        if app.isInstalled == false { parts.append("not installed") }
        parts.append(entry.isExcluded ? "OpenReaction off" : "OpenReaction on")
        return parts.joined(separator: ", ")
    }
}
