#if DEBUG
import AppKit
import OpenReactionCore
import ServiceManagement
import SwiftUI

/// Shows the setup guide, the settings window and every license pill for
/// visual checks: `OpenReaction --preview-setup [directory]`. Debug builds
/// only; release binaries contain none of it (scripts/verify-release.sh
/// checks for the flag).
///
/// Nothing real is touched: a throwaway preferences suite (removed again on
/// quit); a permission provider that reports nothing granted and permission
/// actions that neither ask TCC, open System Settings nor run tccutil; a
/// relauncher that is unavailable, so Relaunch never starts a real copy; a
/// login item that registers only in memory; and — with licensing — an
/// in-memory Keychain, a Dodo client and a trial registry that never answer,
/// so Activate and Try again go nowhere. The event tap is never installed:
/// `AppController.start()` is not called.
///
/// ⌘] and ⌘[ move the guide between steps. With a directory, each window
/// is rendered there in light and dark appearance and the app quits.
@MainActor
final class SetupPreviewHarness {
    nonisolated static let suite = "space.openapps.openreaction.preview-setup"

    private let controller: AppController
    private let loginItem = LoginItem(flags: MemoryFlags(), service: PreviewLoginItemService())
    private let defaults = UserDefaults(suiteName: SetupPreviewHarness.suite)!
    private let onboarding: OnboardingWindowController
    private let settings: SettingsWindowController
    private let pills: NSWindow
    private let titlebar: NSWindow
    private let states = PillStates()
    private var keyMonitor: Any?
    private var timer: Timer?
    private var quitObserver: NSObjectProtocol?

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

    // MARK: - Inert stand-ins

    private final class MemoryFlags: FlagStore {
        var values: [String: Bool] = [:]
        func bool(forKey key: String) -> Bool { values[key] ?? false }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
    }

    /// Nothing granted, nothing asked: the guide sits on its permission steps.
    private struct NoPermissions: PermissionProvider {
        func isGranted(_ kind: PermissionKind) -> Bool { false }
    }

    /// Never asks TCC, never opens System Settings, never runs tccutil: the
    /// guide moves to "waiting" and the reset "succeeds" in memory.
    private struct NoPermissionActions: PermissionActions {
        func request(_ kind: PermissionKind) { print("PREVIEW_PERMISSION_REQUEST \(kind.rawValue)") }
        func reset(_ kind: PermissionKind) async -> String? { print("PREVIEW_PERMISSION_RESET \(kind.rawValue)"); return nil }
        func revealAppInFinder() { print("PREVIEW_REVEAL_IN_FINDER") }
    }

    /// The preview never starts a real copy of the app: Relaunch is disabled.
    private struct NoRelaunch: AppRelauncher {
        var isAvailable: Bool { false }
        func openNewInstance() async -> String? { "Not available in the preview." }
    }

    /// Registers in memory only.
    private final class PreviewLoginItemService: LoginItemService {
        private(set) var status: SMAppService.Status = .notRegistered
        func register() throws { status = .enabled }
        func unregister() throws { status = .notRegistered }
        func openSystemSettings() { print("PREVIEW_OPEN_LOGIN_ITEMS") }
    }

    #if OPENAPPS_LICENSING
    /// A licensed-flavour preview runs the real controller and manager over
    /// these: the "Keychain" holds a registered trial with a day used, and
    /// no service ever answers.
    private final class MemoryLicenseStore: LicenseStore, @unchecked Sendable {
        private let lock = NSLock()
        private var record: LicenseRecord?
        private var cleanups: [PendingCleanup] = []
        func loadRecord() throws(LicenseStoreError) -> LicenseRecord? { lock.withLock { record } }
        func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) { lock.withLock { self.record = record } }
        func clearRecord() throws(LicenseStoreError) { lock.withLock { record = nil } }
        func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] { lock.withLock { cleanups } }
        func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) { lock.withLock { self.cleanups = cleanups } }
    }

    private final class MemoryJournal: InvalidationJournal, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: JournalEntry] = [:]
        func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? { lock.withLock { entries[instanceID] } }
        func record(instanceID: String, entry: JournalEntry) -> Bool {
            lock.withLock {
                if let existing = entries[instanceID], existing.seq >= entry.seq { return true }
                entries[instanceID] = entry
                return true
            }
        }
        func clear(instanceID: String, upTo seq: UInt64) -> Bool {
            lock.withLock {
                if let existing = entries[instanceID], existing.seq > seq { return true }
                entries[instanceID] = nil
                return true
            }
        }
        func replaceUnreadable(instanceID: String, with entry: JournalEntry?) -> Bool { true }
    }

    private final class MemoryTrialStore: TrialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var record: TrialRecord? = TrialRecord(startedAt: Date().addingTimeInterval(-86_400), registered: true)
        func loadTrial() throws(LicenseStoreError) -> TrialRecord? { lock.withLock { record } }
        func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError) { lock.withLock { record = trial } }
    }

    private struct SilentClient: LicenseClient {
        func activate(licenseKey: String, name: String) async -> ActivationResult { .unreachable }
        func validate(licenseKey: String, instanceID: String) async -> ValidationResult { .unreachable }
        func deactivate(licenseKey: String, instanceID: String) async -> DeactivationResult { .unreachable }
    }

    private struct SilentRegistry: TrialRegistryClient {
        func register(device: String) async -> TrialRegistrationResult { .unreachable }
    }

    private struct PreviewDevice: DeviceIdentity {
        func hardwareUUID() -> String? { "00000000-0000-0000-0000-000000000000" }
    }
    #endif

    init(provider: any SuggestionProvider, dataSourceSummary: String, outputDirectory: String?) {
        defaults.removePersistentDomain(forName: Self.suite)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            UserDefaults(suiteName: SetupPreviewHarness.suite)?.removePersistentDomain(forName: SetupPreviewHarness.suite)
        }
        // Never started: no tap, no focus monitor, no relaunch.
        controller = AppController(
            provider: provider, dataSourceSummary: dataSourceSummary, defaults: defaults,
            permissionProvider: NoPermissions(), permissionActions: NoPermissionActions(), relauncher: NoRelaunch()
        )
        onboarding = OnboardingWindowController(controller: controller, loginItem: loginItem, defaults: defaults) { nil }
        #if OPENAPPS_LICENSING
        let license = LicenseController(manager: LicenseManager(
            products: LicenseProducts(paid: ["pdt_preview"]),
            client: SilentClient(),
            store: MemoryLicenseStore(),
            journal: MemoryJournal(),
            trialStore: MemoryTrialStore(),
            registry: SilentRegistry(),
            device: PreviewDevice(),
            trialTiming: .standard
        ))
        license.onChange = { [weak controller, weak license] in
            guard let controller, let license else { return }
            controller.setLicense(allowsFeature: license.isFeatureEnabled, badge: license.badge)
        }
        controller.setLicense(allowsFeature: license.isFeatureEnabled, badge: license.badge)
        license.start()
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
                    if let kind = step.permission {
                        // "Open System Settings" against the inert actions: the
                        // waiting state and the guide panel, nothing else.
                        onboarding.model.request(kind)
                        try? await Task.sleep(for: .milliseconds(500))
                        write(window, to: directory.appendingPathComponent("onboarding-\(step)-requested-\(suffix).png"))
                    }
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
#endif
