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
    var isReady: Bool { permissions.allGranted && isTapRunning && isEnabled }
    /// A packaged `.app` can start a fresh copy of itself; `swift run` builds cannot.
    var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private let provider: any SuggestionProvider
    @ObservationIgnored private let picker = PickerPanelController()
    @ObservationIgnored private let locator = CaretLocator()
    @ObservationIgnored private let focusMonitor = FocusMonitor()
    @ObservationIgnored private var focusGeneration = 0
    @ObservationIgnored private var isRelaunching = false
    @ObservationIgnored private var tap: KeyboardTap?
    /// All keystroke decisions and safety rules; see `TypingCoordinator`.
    @ObservationIgnored private var coordinator: TypingCoordinator
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
        frecency = Self.decode(Frecency.self, key: DefaultsKey.frecency) ?? Frecency()
        let exclusions = Self.decode(AppExclusions.self, key: DefaultsKey.exclusions) ?? AppExclusions()
        self.exclusions = exclusions
        let box = ExclusionsBox(exclusions)
        exclusionsBox = box
        coordinator = TypingCoordinator(
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            isFrontmostAppExcluded: {
                box.value.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
        )
    }

    /// Lets the coordinator's `Sendable` closure read the current exclusions.
    private final class ExclusionsBox: @unchecked Sendable {
        var value: AppExclusions
        init(_ value: AppExclusions) { self.value = value }
    }

    @ObservationIgnored private let exclusionsBox: ExclusionsBox

    func start() {
        tap = KeyboardTap(replayQueue: TextInserter.queue) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        focusMonitor.onFocusChange = { [weak self] in self?.focusMayHaveChanged() }
        picker.onVisibilityChange = { [weak self] frame in
            self?.coordinator.isPickerVisible = frame != nil
            self?.tap?.setPicker(visible: frame != nil, quartzFrame: frame)
        }
        picker.model.onChoose = { [weak self] index in
            guard let self, self.picker.model.suggestions.indices.contains(index) else { return }
            self.picker.select(index)
            // A click is ours alone, so it counts as a swallowed confirm.
            self.run(self.coordinator.handle(.confirm, swallowed: true), keyCode: 0)
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
        exclusions.setExcluded(excluded, bundleIdentifier: bundleIdentifier)
        exclusionsBox.value = exclusions
        Self.encode(exclusions, key: DefaultsKey.exclusions)
        resetTyping()
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
        tap?.stop()
        focusMonitor.stop()
        resetTyping()
        isTapRunning = false

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

    // MARK: - Tap lifecycle

    /// Runs the tap only while both permissions are granted and the user has
    /// not paused OpenReaction. Called on every permission poll, so access
    /// granted in System Settings takes effect without a relaunch, and access
    /// revoked there stops the tap. Every start attempt is reported to the
    /// permission flow, which decides when failures mean "relaunch" or "stale".
    func updateTap() {
        guard let tap, !isRelaunching else { return }
        let wasReady = isReady
        if permissions.allGranted && isEnabled {
            if !tap.isRunning {
                let running = tap.start()
                permissions.recordTap(running: running)
                if running {
                    focusMonitor.start()
                    focusMayHaveChanged()
                }
            }
        } else if tap.isRunning {
            tap.stop()
            focusMonitor.stop()
            resetTyping()
        }
        if isTapRunning != tap.isRunning { isTapRunning = tap.isRunning }
        if wasReady != isReady { onStateChange?() }
    }

    // MARK: - Input

    private func handle(_ event: TapEvent) {
        run(coordinator.handle(event.input, swallowed: event.swallowed), keyCode: event.keyCode)
        // Keys that reach the host and may move focus (Tab, Return, clicks,
        // navigation) get a re-check, for apps that post no focus notifications.
        if event.input == .reset || (event.input == .confirm && !event.swallowed) {
            focusMayHaveChanged(assumeMoved: false)
        }
    }

    private func resetTyping() {
        run(coordinator.handle(.reset), keyCode: 0)
    }

    /// Re-checks the focused element. When focus is known to have moved,
    /// capture stops until the answer arrives; otherwise the current knowledge
    /// stands until it is replaced.
    private func focusMayHaveChanged(assumeMoved: Bool = true) {
        if assumeMoved {
            run(coordinator.focusChanged(.unavailable), keyCode: 0)
        }
        let generation = focusGeneration &+ 1
        focusGeneration = generation
        Task {
            let info = await locator.focusInfo()
            guard generation == focusGeneration else { return }
            run(coordinator.focusChanged(focusResult(info)), keyCode: 0)
        }
    }

    private func run(_ effects: [TypingCoordinator.Effect], keyCode: CGKeyCode) {
        for effect in effects {
            switch effect {
            case .requestFocus(let tokenID):
                Task {
                    let info = await locator.focusInfo()
                    run(coordinator.focusResolved(tokenID: tokenID, focusResult(info)), keyCode: 0)
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
            case .insert(let insertion):
                perform(insertion)
            case .repost:
                // The tap removed a key the picker could not use; send it on so
                // the user's keystroke is not lost.
                if keyCode != 0 { TextInserter.repost(keyCode: keyCode) }
            }
        }
        tap?.setCapturesText(coordinator.capturesText)
    }

    // MARK: - Focus and insertion

    /// Converts Accessibility geometry to the coordinator's view of focus.
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

    /// Carries out one replacement as a transaction: hold physical keys, verify
    /// the target field still has focus with the typed token before the caret,
    /// post the deletes and the emoji, then let held keys through in order.
    private func perform(_ insertion: Insertion) {
        let suggestion: Suggestion?
        switch insertion.source {
        case .selection: suggestion = picker.selectedSuggestion
        case .shortcode(let shortcode): suggestion = provider.exactMatch(for: shortcode)
        }
        picker.dismiss()
        guard let suggestion, case .text(let text) = suggestion.payload, let tap, !IsSecureEventInputEnabled() else {
            run(coordinator.insertionFinished(insertion, inserted: nil), keyCode: 0)
            return
        }

        tap.beginHold()
        // If the flush never comes back (tap disabled mid-way), release the keys.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            tap.endHold()
            run(coordinator.insertionFinished(insertion, inserted: nil), keyCode: 0)
        }

        Task {
            guard await locator.verify(insertion.target, typed: insertion.typed) else {
                deadline.cancel()
                TextInserter.postFlush()
                run(coordinator.insertionFinished(insertion, inserted: nil), keyCode: 0)
                return
            }
            TextInserter.replace(deleting: insertion.replacingCount, with: text) {
                Task { @MainActor in
                    deadline.cancel()
                    self.run(self.coordinator.insertionFinished(insertion, inserted: text), keyCode: 0)
                    self.frecency.record(suggestion.id)
                    Self.encode(self.frecency, key: DefaultsKey.frecency)
                }
            }
        }
    }

    /// Forgets which emoji were picked. Nothing else about typing is ever kept.
    func clearUsageHistory() {
        frecency.removeAll()
        UserDefaults.standard.removeObject(forKey: DefaultsKey.frecency)
    }

    var hasUsageHistory: Bool { !frecency.isEmpty }

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
