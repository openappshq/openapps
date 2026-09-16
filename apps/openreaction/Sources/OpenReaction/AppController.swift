import AppKit
import Carbon.HIToolbox
import OpenAppsLicensing
import OpenReactionCore
import os

/// The synchronous feature lock: whoever holds it can stop the gate from
/// authorizing, from any thread, whether or not the runner exists yet.
final class FeatureLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var runner: GateRunner?

    func attach(_ runner: GateRunner) {
        mutex.withLock { self.runner = runner }
    }

    /// Begins the gate's shutdown now. A tap installed later resets it.
    func pull() {
        let runner = mutex.withLock { self.runner }
        runner?.beginShutdown()
    }
}

/// Starts a fresh copy of the app, behind `AppController.relaunch()`, so the
/// debug preview harness can stand in one that starts nothing.
@MainActor
protocol AppRelauncher {
    /// A packaged `.app` can start a fresh copy of itself; `swift run` builds cannot.
    var isAvailable: Bool { get }
    /// Opens a new instance. Returns an error message, or nil once it runs.
    func openNewInstance() async -> String?
}

struct WorkspaceRelauncher: AppRelauncher {
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func openNewInstance() async -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
                let message = error?.localizedDescription
                let launched = app != nil && error == nil
                continuation.resume(returning: launched ? nil : (message ?? "OpenReaction couldn't open a new copy of itself."))
            }
        }
    }
}

/// Connects the event tap, trigger state machine, suggestion provider, caret
/// lookup, picker and insertion. Everything here runs on the main thread;
/// the tap and accessibility queries hand results over asynchronously.
@MainActor
@Observable
final class AppController {
    let permissions: PermissionMonitor
    private(set) var isEnabled: Bool
    private(set) var exclusions: AppExclusions
    /// Apps where the typed-replacement fallback is switched off (default on).
    private(set) var typedReplacement: TypedReplacementSettings
    private(set) var isTapRunning = false
    /// Set when `relaunch()` could not start a new instance.
    private(set) var relaunchError: String?
    /// Something the user should know about held typing: it could not be
    /// restored, or restoring it is taking unusually long.
    private(set) var inputNotice: String?

    /// Permissions report granted but macOS still refuses the tap.
    var needsRelaunch: Bool { permissions.snapshot.isTapFailing }
    var isReady: Bool { permissions.allGranted && isTapRunning && isEnabled && isLicensedForFeature }

    /// Whether the license allows the picker. Always true in builds with
    /// licensing compiled out; official builds set it from the license state.
    /// A locked state stops only the picker: the tap is not started.
    private(set) var isLicensedForFeature = true
    /// The trial's remaining time or the short reason the license keeps the
    /// picker off, for the status menu and onboarding; nil while licensed
    /// and in builds without licensing.
    private(set) var licenseBadge: LicenseBadge.Label?

    func setLicense(allowsFeature: Bool, badge: LicenseBadge.Label?) {
        licenseBadge = badge
        guard isLicensedForFeature != allowsFeature else { return }
        isLicensedForFeature = allowsFeature
        updateTap()
    }
    /// A packaged `.app` can start a fresh copy of itself; `swift run` builds cannot.
    var canRelaunch: Bool { relauncher.isAvailable }

    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private let provider: any SuggestionProvider
    @ObservationIgnored private let picker = PickerPanelController()
    @ObservationIgnored private let locator = CaretLocator()
    @ObservationIgnored private let focusMonitor = FocusMonitor()
    @ObservationIgnored private var isRelaunching = false
    @ObservationIgnored private var tap: KeyboardTap?
    /// All keystroke decisions and safety rules live in the core `InputGate`;
    /// the runner serializes inputs to it and carries out its effects.
    @ObservationIgnored private var runner: GateRunner?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var pendingSuggestions: [Int: Suggestion] = [:]
    @ObservationIgnored private var frecency: Frecency
    /// Which emoji data is in use, for About and diagnostics.
    @ObservationIgnored let dataSourceSummary: String
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let relauncher: any AppRelauncher

    private enum DefaultsKey {
        static let enabled = "enabled"
        static let frecency = "frecency"
        static let exclusions = "exclusions"
        static let typedReplacement = "typedReplacement"
    }

    /// `defaults`, the permission provider and actions, and the relauncher
    /// are the app's own except in the debug preview harness, which passes
    /// a throwaway suite and stand-ins that touch nothing.
    init(
        provider: any SuggestionProvider,
        dataSourceSummary: String,
        defaults: UserDefaults = .standard,
        permissionProvider: any PermissionProvider = SystemPermissionProvider(),
        permissionActions: any PermissionActions = SystemPermissionActions(),
        relauncher: any AppRelauncher = WorkspaceRelauncher()
    ) {
        self.provider = provider
        self.dataSourceSummary = dataSourceSummary
        self.defaults = defaults
        self.relauncher = relauncher
        permissions = PermissionMonitor(provider: permissionProvider, actions: permissionActions, defaults: defaults)
        isEnabled = defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? true
        hasStoredUsage = defaults.data(forKey: DefaultsKey.frecency) != nil
        if let stored = Self.decode(Frecency.self, key: DefaultsKey.frecency, defaults: defaults) {
            frecency = stored
            // Rewrites entries from the first release in the day-based format.
            Self.encode(stored, key: DefaultsKey.frecency, defaults: defaults)
        } else {
            frecency = Frecency()
        }
        exclusions = Self.decode(AppExclusions.self, key: DefaultsKey.exclusions, defaults: defaults) ?? AppExclusions()
        typedReplacement = Self.decode(TypedReplacementSettings.self, key: DefaultsKey.typedReplacement, defaults: defaults) ?? TypedReplacementSettings()
    }

    func start() {
        let runner = GateRunner(gate: InputGate()) { [weak self] effects in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.perform(effects) }
            }
        }
        self.runner = runner
        lock.attach(runner)
        tap = KeyboardTap(runner: runner)
        focusMonitor.isExcluded = { [weak self] bundleIdentifier in
            self?.exclusions.isExcluded(bundleIdentifier) ?? false
        }
        focusMonitor.onFocusChange = { [weak self] in
            guard let self else { return }
            self.pushFrontmostExclusion()
            self.runner?.focusMayHaveMoved()
        }
        focusMonitor.onTrackingChange = { [weak self] active in self?.runner?.focusTracking(active: active) }
        picker.onVisibilityChange = { [weak self] frame in
            self?.runner?.pickerVisibility(frame)
        }
        picker.model.onChoose = { [weak self] index in
            guard let self, self.picker.model.suggestions.indices.contains(index) else { return }
            self.picker.select(index)
            self.runner?.pickerClicked()
        }
        picker.model.onHover = { [weak self] index in self?.picker.select(index) }

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetTyping() }
        })

        permissions.onPoll = { [weak self] in self?.updateTap() }
        permissions.start()
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.enabled)
        updateTap()
    }

    func setExcluded(_ excluded: Bool, bundleIdentifier: String) {
        updateExclusions { $0.setExcluded(excluded, bundleIdentifier: bundleIdentifier) }
    }

    func addExclusions(_ bundleIdentifiers: [String]) {
        updateExclusions { $0.add(bundleIdentifiers) }
    }

    func removeExclusion(_ bundleIdentifier: String) {
        updateExclusions { $0.remove(bundleIdentifier) }
    }

    func restoreDefaultExclusions() {
        updateExclusions { $0.restoreDefaults() }
    }

    func setTypedReplacement(_ enabled: Bool, bundleIdentifier: String) {
        updateTypedReplacement { $0.setEnabled(enabled, bundleIdentifier: bundleIdentifier) }
    }

    func disableTypedReplacement(_ bundleIdentifiers: [String]) {
        updateTypedReplacement { $0.disable(bundleIdentifiers) }
    }

    func restoreDefaultTypedReplacement() {
        updateTypedReplacement { $0.restoreDefaults() }
    }

    /// Single write path for the typed-replacement list, mirroring exclusions:
    /// persisted, and the frontmost app's new answer pushed to the gate at once.
    private func updateTypedReplacement(_ change: (inout TypedReplacementSettings) -> Void) {
        var updated = typedReplacement
        change(&updated)
        guard updated != typedReplacement else { return }
        typedReplacement = updated
        Self.encode(typedReplacement, key: DefaultsKey.typedReplacement, defaults: defaults)
        pushFrontmostExclusion()
        resetTyping()
    }

    /// Single write path: `exclusions` is the observed source of truth for
    /// Settings and the status menu; the gate gets the frontmost app's new
    /// answer at once.
    private func updateExclusions(_ change: (inout AppExclusions) -> Void) {
        var updated = exclusions
        change(&updated)
        guard updated != exclusions else { return }
        exclusions = updated
        Self.encode(exclusions, key: DefaultsKey.exclusions, defaults: defaults)
        pushFrontmostExclusion()
        resetTyping()
    }

    /// The gate never touches AppKit: the frontmost app's exclusion and its
    /// typed-replacement answer are computed here and handed in as locked
    /// inputs.
    private func pushFrontmostExclusion() {
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        runner?.frontmostApp(
            excluded: exclusions.isExcluded(bundleIdentifier),
            typedReplacement: typedReplacement.isEnabled(bundleIdentifier)
        )
    }

    /// Starts a new instance, then quits this one once it is running.
    ///
    /// The tap stops first so two instances never handle the same keystrokes.
    /// If the new instance cannot be opened, this one keeps running and
    /// restarts its tap. The relaunch is recorded so a tap that still fails in
    /// the new process is reported as a stale permission, not another relaunch.
    func relaunch() {
        guard !isRelaunching else { return }
        guard canRelaunch else {
            relaunchError = "Quit OpenReaction and open it again."
            return
        }
        relaunchError = nil
        isRelaunching = true
        permissions.willRelaunch()
        Task {
            await stopTapDraining()
            if let message = await relauncher.openNewInstance() {
                isRelaunching = false
                relaunchError = message
                permissions.relaunchFailed()
                updateTap()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    /// A lock the license layer can pull from any thread, synchronously:
    /// the gate stops authorizing at once (commits queued on the insertion
    /// queue are refused from here on) and everything it holds drains
    /// through the normal stop, which `setLicense` then completes on main.
    /// Resolves the runner when pulled, so it may be handed out before
    /// `start()` creates the runner.
    func featureLock() -> @Sendable () -> Void {
        let lock = self.lock
        return { lock.pull() }
    }

    /// The runner the feature lock reaches, from any thread.
    @ObservationIgnored private let lock = FeatureLock()

    /// Called before the process exits, so held input reaches the host.
    /// Returns how the drain ended; only `.delivered` is a confirmed delivery.
    @discardableResult
    func prepareToQuit() async -> InputGate.ShutdownOutcome {
        isRelaunching = true // no restarts from the permission poll meanwhile
        return await stopTapDraining()
    }

    /// A quit that was prepared but then refused (an update's restart
    /// failed): the tap may run again.
    func resumeAfterCancelledQuit() {
        isRelaunching = false
        updateTap()
        onStateChange?()
    }

    /// How long a deliberate stop waits for the tap's acknowledgements; past
    /// it what is owed is replayed unacknowledged (`.failed`) while the tap
    /// is still installed. Never "delivered".
    static let acknowledgementBound: Duration = .seconds(10)
    /// How long it then waits for the posting queue to run that replay
    /// before saying that it is taking unusually long. The wait itself goes
    /// on: the tap is never stopped with a replay still queued.
    static let replayBound: Duration = .seconds(10)
    private static let log = Logger(subsystem: "com.openappshq.openreaction", category: "tap")

    /// Stops the tap without reordering input. Focus tracking stops first so
    /// nothing can reopen capture; the gate stops authorizing at once, and
    /// everything it still owes the host (held keys, and input typed while
    /// they drain) goes out through acknowledged flushes while the tap owns
    /// the stream. Only then is the tap uninstalled.
    ///
    /// The wait ends with the gate's outcome: `.delivered` when the tap
    /// acknowledged everything; `.interrupted` when macOS disabled the tap and
    /// the best-effort replay has run; `.failed` when a flush could not be
    /// posted, or no acknowledgement came within `acknowledgementBound`, and
    /// the replay has run anyway. A replay the posting queue has not run
    /// within `replayBound` is reported to the user and waited for: the tap
    /// stays installed and holding until it ran (or the user force-quits).
    /// Anything but delivery is logged.
    @discardableResult
    private func stopTapDraining() async -> InputGate.ShutdownOutcome {
        guard let tap, let runner, tap.isRunning else { return .delivered }
        // Focus tracking keeps running: the gate ignores it for capture now,
        // but a focus change still stops a delayed replay from going astray.
        runner.beginShutdown()
        let outcome = await runner.awaitShutdown(
            acknowledgementBound: Self.acknowledgementBound, replayBound: Self.replayBound
        ) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.reportStuckInput() }
            }
        }
        stuckPanel?.close()
        stuckPanel = nil
        if outcome != .delivered {
            Self.log.error("Tap stopped without confirmed delivery of held input: \(String(describing: outcome), privacy: .public)")
        }
        tap.stop() // reports `tapStopped` to the gate; anything still held goes out as a last resort
        focusMonitor.stop()
        if isTapRunning { isTapRunning = false }
        return outcome
    }

    @ObservationIgnored private var stuckPanel: StuckInputPanel?

    /// The replay bound passed: say so where it can be seen and used —
    /// input aimed at our own windows is never held — and offer the choice
    /// between waiting and discarding.
    private func reportStuckInput() {
        Self.log.error("Held typing is still being restored; the tap stays installed until it is.")
        inputNotice = "Still restoring typing that was held back…"
        showStuckPanel(reason: .slow)
    }

    private func showStuckPanel(reason: StuckInputPanel.Reason) {
        if let stuckPanel {
            stuckPanel.show(reason: reason)
            return
        }
        let panel = StuckInputPanel(keepWaiting: {}, discard: { [weak self] in
            self?.runner?.discardHeldInput()
        })
        stuckPanel = panel
        panel.show(reason: reason)
    }

    // MARK: - Tap lifecycle

    /// Runs the tap only while both permissions are granted and the user has
    /// not paused OpenReaction. Called on every permission poll, so access
    /// granted in System Settings takes effect without a relaunch, and access
    /// revoked there stops the tap. Every start attempt is reported to the
    /// permission flow, which decides when failures mean "relaunch" or "stale".
    func updateTap() {
        guard let tap, !isRelaunching, !isStoppingTap else { return }
        let wasReady = isReady
        if permissions.allGranted && isEnabled && isLicensedForFeature {
            if !tap.isRunning {
                let running = tap.start()
                permissions.recordTap(running: running)
                if running {
                    focusMonitor.start()
                }
            }
        } else if tap.isRunning {
            isStoppingTap = true
            Task {
                await stopTapDraining()
                isStoppingTap = false
                updateTap()
                onStateChange?()
            }
        }
        if isTapRunning != tap.isRunning { isTapRunning = tap.isRunning }
        if wasReady != isReady { onStateChange?() }
    }

    @ObservationIgnored private var isStoppingTap = false

    // MARK: - Gate effects

    /// Runs the effects the gate handed to the main actor, in order.
    private func perform(_ effects: [GateRunner.MainEffect]) {
        for effect in effects {
            switch effect {
            case .requestProbe(let generation, let tokenID):
                Task {
                    let info = await locator.focusInfo()
                    runner?.probeResult(generation: generation, tokenID: tokenID, focusResult(info))
                }
            case .checkDestination(let transaction, let target):
                // A delayed replay goes only into the field it was typed in;
                // a password field or an unreadable focus never matches.
                Task {
                    let info = await locator.focusInfo()
                    let matches: Bool
                    if case .editable(_, let current) = focusResult(info) { matches = current == target } else { matches = false }
                    runner?.destinationChecked(transaction: transaction, matches: matches)
                }
            case .inputLost(let eventCount):
                Self.log.error("Dropped \(eventCount) held key events: the focused field changed before they could be restored.")
                inputNotice = "Some typing couldn’t be restored: the focused field changed while OpenReaction was stopping."
            case .destinationChanged:
                // Held typing waits for its field to come back; the user can
                // switch back to it, keep waiting, or discard.
                Self.log.error("Held typing is waiting: the focused field changed before it could be restored.")
                inputNotice = "Typing held back is waiting for its field: switch back to it, or discard it."
                showStuckPanel(reason: .fieldChanged)
            case .presentPicker(let query, let anchor):
                let suggestions = provider.suggestions(for: query, usage: frecency.scores(), limit: PickerMetrics.maxItems)
                if suggestions.isEmpty {
                    picker.dismiss()
                } else {
                    picker.present(suggestions, caret: anchor)
                }
            case .dismissPicker:
                picker.dismiss()
            case .moveSelection(let delta):
                picker.moveSelection(by: delta)
            case .beginInsertion(let transaction, let source, let typed, let target):
                beginInsertion(transaction: transaction, source: source, typed: typed, target: target)
            case .armWatchdog(let transaction):
                armWatchdog(transaction: transaction)
            case .transactionEnded(let transaction, let recordUse):
                watchdog?.cancel()
                watchdog = nil
                let suggestion = pendingSuggestions.removeValue(forKey: transaction)
                if recordUse, let suggestion {
                    frecency.record(suggestion.id)
                    Self.encode(frecency, key: DefaultsKey.frecency, defaults: defaults)
                    hasStoredUsage = true
                }
            }
        }
    }

    private func armWatchdog(transaction: Int) {
        watchdog?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.runner?.timeout(transaction: transaction)
        }
        watchdog = task
    }

    /// Resolves what to insert and verifies the target while the gate holds
    /// physical keys. The answer goes back through the runner; the gate
    /// decides whether it is still allowed to post.
    private func beginInsertion(transaction: Int, source: InsertionSource, typed: String, target: FocusTarget) {
        picker.dismiss()
        let suggestion: Suggestion?
        switch source {
        case .selection: suggestion = picker.selectedSuggestion
        case .shortcode(let shortcode): suggestion = provider.exactMatch(for: shortcode)
        }
        guard let suggestion, case .text(let text) = suggestion.payload, !IsSecureEventInputEnabled() else {
            runner?.verifyResult(transaction: transaction, .refused)
            return
        }
        pendingSuggestions[transaction] = suggestion
        Task {
            let result = await locator.verify(target, typed: typed, text: text)
            runner?.verifyResult(transaction: transaction, result)
        }
    }

    private func resetTyping() {
        runner?.focusMayHaveMoved()
    }

    /// Converts Accessibility geometry to the gate's view of focus.
    /// A non-secure field with no geometry anchors below the mouse pointer.
    private func focusResult(_ info: FocusInfo) -> FocusResult {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        switch info {
        case .secure:
            return .secure
        case .unavailable:
            return .unavailable
        case .caret(let rect, let target):
            return .editable(anchor: PanelPlacement.appKitRect(fromQuartz: rect, primaryScreenHeight: primaryHeight), target: target)
        case .element(let frame, let target):
            let rect = PanelPlacement.appKitRect(fromQuartz: frame, primaryScreenHeight: primaryHeight)
            return .editable(anchor: CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height), target: target)
        case .noGeometry(let target):
            let mouse = NSEvent.mouseLocation
            return .editable(anchor: CGRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 24), target: target)
        }
    }

    /// Forgets which emoji were picked. Nothing else about typing is ever kept.
    func clearUsageHistory() {
        frecency.removeAll()
        defaults.removeObject(forKey: DefaultsKey.frecency)
        hasStoredUsage = false
    }

    /// Whether anything is on disk, including data this build could not read.
    private(set) var hasStoredUsage: Bool
    var hasUsageHistory: Bool { !frecency.isEmpty || hasStoredUsage }

    // MARK: - Persistence

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
