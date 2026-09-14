import AppKit
import Carbon.HIToolbox
import OpenReactionCore

/// Connects the event tap, trigger state machine, suggestion provider, caret
/// lookup, picker and insertion. Everything here runs on the main thread;
/// the tap and accessibility queries hand results over asynchronously.
@MainActor
@Observable
final class AppController {
    let permissions = PermissionMonitor()
    private(set) var isEnabled: Bool
    private(set) var exclusions: AppExclusions
    private(set) var isTapRunning = false
    /// Set when `relaunch()` could not start a new instance.
    private(set) var relaunchError: String?

    /// Permissions report granted but macOS still refuses the tap.
    var needsRelaunch: Bool { permissions.snapshot.isTapFailing }
    var isReady: Bool { permissions.allGranted && isTapRunning && isEnabled && isLicensedForFeature }

    /// Whether the license allows the picker. Always true in builds with
    /// licensing compiled out; official builds set it from the license state.
    /// A locked state stops only the picker: the tap is not started.
    private(set) var isLicensedForFeature = true
    /// Status-menu line while the license needs attention, or nil.
    private(set) var licenseStatusLine: String?

    func setLicense(allowsFeature: Bool, statusLine: String?) {
        licenseStatusLine = statusLine
        guard isLicensedForFeature != allowsFeature else { return }
        isLicensedForFeature = allowsFeature
        updateTap()
    }
    /// A packaged `.app` can start a fresh copy of itself; `swift run` builds cannot.
    var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

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

    private enum DefaultsKey {
        static let enabled = "enabled"
        static let frecency = "frecency"
        static let exclusions = "exclusions"
    }

    init(provider: any SuggestionProvider, dataSourceSummary: String) {
        self.provider = provider
        self.dataSourceSummary = dataSourceSummary
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? true
        hasStoredUsage = defaults.data(forKey: DefaultsKey.frecency) != nil
        if let stored = Self.decode(Frecency.self, key: DefaultsKey.frecency) {
            frecency = stored
            // Rewrites entries from the first release in the day-based format.
            Self.encode(stored, key: DefaultsKey.frecency)
        } else {
            frecency = Frecency()
        }
        exclusions = Self.decode(AppExclusions.self, key: DefaultsKey.exclusions) ?? AppExclusions()
    }

    func start() {
        let runner = GateRunner(gate: InputGate()) { [weak self] effects in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.perform(effects) }
            }
        }
        self.runner = runner
        tap = KeyboardTap(runner: runner)
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
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.enabled)
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

    /// Single write path: `exclusions` is the observed source of truth for
    /// Settings and the status menu; the gate gets the frontmost app's new
    /// answer at once.
    private func updateExclusions(_ change: (inout AppExclusions) -> Void) {
        var updated = exclusions
        change(&updated)
        guard updated != exclusions else { return }
        exclusions = updated
        Self.encode(exclusions, key: DefaultsKey.exclusions)
        pushFrontmostExclusion()
        resetTyping()
    }

    /// The gate never touches AppKit: the frontmost app's exclusion is
    /// computed here and handed in as a locked input.
    private func pushFrontmostExclusion() {
        runner?.frontmostApp(excluded: exclusions.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
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
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
                let message = error?.localizedDescription
                let launched = app != nil && error == nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if launched {
                            NSApp.terminate(nil)
                        } else {
                            self.isRelaunching = false
                            self.relaunchError = message ?? "OpenReaction couldn't open a new copy of itself."
                            self.permissions.relaunchFailed()
                            self.updateTap()
                        }
                    }
                }
            }
        }
    }

    /// Called before the process exits, so held input reaches the host.
    func prepareToQuit() async {
        isRelaunching = true // no restarts from the permission poll meanwhile
        await stopTapDraining()
    }

    /// Stops the tap without reordering input: the gate stops authorizing at
    /// once, everything it still owes the host drains through acknowledged
    /// flushes while the tap owns the stream, and only then is the tap
    /// uninstalled. Bounded by the gate's own watchdogs.
    private func stopTapDraining() async {
        guard let tap, let runner, tap.isRunning else { return }
        runner.beginShutdown()
        let deadline = ContinuousClock.now + .seconds(3)
        while !runner.isIdle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        runner.tapStopped()
        tap.stop()
        focusMonitor.stop()
        if isTapRunning { isTapRunning = false }
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
                    Self.encode(frecency, key: DefaultsKey.frecency)
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
        UserDefaults.standard.removeObject(forKey: DefaultsKey.frecency)
        hasStoredUsage = false
    }

    /// Whether anything is on disk, including data this build could not read.
    private(set) var hasStoredUsage: Bool
    var hasUsageHistory: Bool { !frecency.isEmpty || hasStoredUsage }

    // MARK: - Persistence

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
