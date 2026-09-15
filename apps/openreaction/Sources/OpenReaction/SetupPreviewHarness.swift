import AppKit
import OpenReactionCore
import SwiftUI

/// Shows the setup guide, the settings window and every license pill
/// without the event tap, permissions, storage or the network, for visual
/// checks: `OpenReaction --preview-setup [directory]`.
///
/// ⌘] and ⌘[ move the guide between steps. With a directory, each window
/// is rendered there in light and dark appearance and the app quits.
@MainActor
final class SetupPreviewHarness {
    private let controller: AppController
    private let loginItem = LoginItem(flags: MemoryFlags())
    private let defaults = UserDefaults(suiteName: "space.openapps.openreaction.preview-setup")!
    private let onboarding: OnboardingWindowController
    private let settings: SettingsWindowController
    private let pills: NSWindow
    private let titlebar: NSWindow
    private let states = PillStates()
    private var keyMonitor: Any?
    private var timer: Timer?

    /// The pill states side by side; the title bar sample cycles through them.
    @MainActor
    @Observable
    final class PillStates {
        let all: [LicenseBadge.Label] = [
            .trial(daysLeft: 3), .trial(daysLeft: 2), .trial(daysLeft: 1), .trialUnavailable, .trialEnded,
            .trialNeedsConnection, .trialClockBehind, .grace(daysLeft: 2, showWarning: true), .checkRequired, .revoked,
        ].compactMap { LicenseBadge.label(for: $0) }
        var index = 0
        var current: LicenseBadge.Label? { all[index % all.count] }
    }

    private final class MemoryFlags: FlagStore {
        var values: [String: Bool] = [:]
        func bool(forKey key: String) -> Bool { values[key] ?? false }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
    }

    init(provider: any SuggestionProvider, dataSourceSummary: String, outputDirectory: String?) {
        defaults.removePersistentDomain(forName: "space.openapps.openreaction.preview-setup")
        // Never started: no tap, no permission polling, no relaunch.
        controller = AppController(provider: provider, dataSourceSummary: dataSourceSummary)
        onboarding = OnboardingWindowController(controller: controller, loginItem: loginItem, defaults: defaults) { nil }
        #if OPENAPPS_LICENSING
        // Never started: no storage, no registry, no Dodo. The pill reads
        // "Starting your free trial…", the state before storage is read.
        let license = LicenseController(manager: LicenseManager(
            products: LicensingConfig.products,
            client: DodoLicenseClient(host: LicensingConfig.host),
            store: KeychainLicenseStore(),
            journal: DefaultsInvalidationJournal(),
            trialStore: KeychainTrialStore(),
            registry: URLSessionTrialRegistryClient(endpoint: LicensingConfig.trialRegistryURL, environment: LicensingConfig.environment),
            device: PlatformDeviceIdentity(),
            trialTiming: Licensing.trialTiming
        ))
        controller.setLicense(allowsFeature: license.isFeatureEnabled, badge: license.badge)
        settings = SettingsWindowController(controller: controller, loginItem: loginItem, license: license) { [onboarding] in
            onboarding.show()
        }
        #else
        settings = SettingsWindowController(controller: controller, loginItem: loginItem) { [onboarding] in
            onboarding.show()
        }
        #endif
        onboarding.model.onOpenLicense = { [settings] in settings.showLicense() }

        pills = Self.window(title: "License pills", size: CGSize(width: 900, height: 420))
        pills.contentView = NSHostingView(rootView: PillGallery(labels: states.all) {})
        titlebar = Self.window(title: "Title bar sample", size: CGSize(width: 520, height: 120))
        titlebar.contentView = NSHostingView(rootView: Text("The pill above cycles through every state.")
            .font(Brand.body(14)).foregroundStyle(Brand.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.canvas))
        titlebar.addTitlebarAccessoryViewController(LicensePillAccessory(badge: { [states] in states.current }) {
            print("PREVIEW_PILL_CLICKED")
        })

        settings.show()
        onboarding.show()
        pills.makeKeyAndOrderFront(nil)
        titlebar.makeKeyAndOrderFront(nil)
        NSApp.activate()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command), let self else { return event }
            switch event.charactersIgnoringModifiers {
            case "]": self.step(by: 1); return nil
            case "[": self.step(by: -1); return nil
            default: return event
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [states] _ in
            MainActor.assumeIsolated { states.index += 1 }
        }

        if let outputDirectory {
            Task { await self.render(to: URL(fileURLWithPath: outputDirectory)) }
        }
    }

    private func step(by delta: Int) {
        let all = OnboardingStep.allCases
        let current = all.firstIndex(of: onboarding.model.displayedStep) ?? 0
        onboarding.model.previewStep = all[(current + delta + all.count) % all.count]
    }

    private static func window(title: String, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    // MARK: - Rendering

    /// Every window, every guide step and both appearances, as PNGs.
    private func render(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(600))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for window in NSApp.windows where window.isVisible {
                window.appearance = NSAppearance(named: appearance)
            }
            try? await Task.sleep(for: .milliseconds(400))
            for step in OnboardingStep.allCases {
                onboarding.model.previewStep = step
                try? await Task.sleep(for: .milliseconds(500))
                if let window = NSApp.windows.first(where: { $0.title == "Set Up OpenReaction" }) {
                    write(window, to: directory.appendingPathComponent("onboarding-\(step)-\(suffix).png"))
                }
            }
            write(pills, to: directory.appendingPathComponent("pills-\(suffix).png"))
            states.index = 0
            try? await Task.sleep(for: .milliseconds(300))
            write(titlebar, to: directory.appendingPathComponent("titlebar-trial-\(suffix).png"))
            states.index = 4
            try? await Task.sleep(for: .milliseconds(300))
            write(titlebar, to: directory.appendingPathComponent("titlebar-ended-\(suffix).png"))
            if let window = NSApp.windows.first(where: { $0.title == "OpenReaction Settings" }) {
                write(window, to: directory.appendingPathComponent("settings-\(suffix).png"))
                settings.showLicense()
                try? await Task.sleep(for: .milliseconds(600))
                write(window, to: directory.appendingPathComponent("settings-license-\(suffix).png"))
            }
        }
        print("PREVIEW_RENDERED \(directory.path)")
        NSApp.terminate(nil)
    }

    /// The whole window as composited on screen, title bar included.
    /// `NSView.cacheDisplay` misses layer-backed SwiftUI content and
    /// ScreenCaptureKit needs Screen Recording permission, so this uses
    /// `CGWindowListCreateImage`, which still captures a process's own
    /// windows without it. It is deprecated; looking it up by name keeps the
    /// build warning-free.
    private func write(_ window: NSWindow, to url: URL) {
        window.orderFrontRegardless()
        typealias Capture = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        guard let image = capture(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            print("PREVIEW_CAPTURE_FAILED \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image.takeRetainedValue())
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

/// Every pill state in a column, with what the status menu would say.
private struct PillGallery: View {
    let labels: [LicenseBadge.Label]
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            MonoLabel("License pill · every state")
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                HStack(spacing: Brand.Space.s16) {
                    LicensePill(label: label, action: action)
                    Text(label.tone == .trial ? "feature on" : "attention")
                        .font(Brand.mono(11))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .padding(Brand.Space.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.canvas)
    }
}
