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
        tap = KeyboardTap { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        picker.onVisibilityChange = { [weak self] frame in
            self?.coordinator.isPickerVisible = frame != nil
            self?.tap?.setPicker(visible: frame != nil, quartzFrame: frame)
        }
        picker.model.onChoose = { [weak self] index in
            guard let self, self.picker.model.suggestions.indices.contains(index) else { return }
            self.picker.model.selectedIndex = index
            // A click is ours alone, so it counts as a swallowed confirm.
            self.run(self.coordinator.handle(.confirm, swallowed: true), keyCode: 0)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetTyping() }
        })
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
        guard canRelaunch else {
            relaunchError = "Quit OpenReaction and open it again."
            return
        }
        relaunchError = nil
        permissions.willRelaunch()
        tap?.stop()
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
        guard let tap else { return }
        let wasReady = isReady
        if permissions.allGranted && isEnabled {
            if !tap.isRunning {
                permissions.recordTap(running: tap.start())
            }
        } else if tap.isRunning {
            tap.stop()
            resetTyping()
        }
        if isTapRunning != tap.isRunning { isTapRunning = tap.isRunning }
        if wasReady != isReady { onStateChange?() }
    }

    // MARK: - Input

    private func handle(_ event: TapEvent) {
        run(coordinator.handle(event.input, swallowed: event.swallowed), keyCode: event.keyCode)
    }

    private func resetTyping() {
        run(coordinator.reset(), keyCode: 0)
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
            case .commitSelection(let count):
                if let suggestion = picker.selectedSuggestion {
                    insert(suggestion, replacing: count)
                } else {
                    resetTyping()
                }
            case .insertShortcode(let shortcode, let count):
                if let suggestion = provider.exactMatch(for: shortcode) {
                    insert(suggestion, replacing: count)
                }
            case .repost:
                // The tap removed a key the picker could not use; send it on so
                // the user's keystroke is not lost.
                if keyCode != 0 { TextInserter.repost(keyCode: keyCode) }
            }
        }
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
        case .caret(let rect):
            return .editable(anchor: PanelPlacement.appKitRect(fromQuartz: rect, primaryScreenHeight: primaryHeight))
        case .element(let frame):
            let rect = PanelPlacement.appKitRect(fromQuartz: frame, primaryScreenHeight: primaryHeight)
            return .editable(anchor: CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height))
        case .noGeometry:
            let mouse = NSEvent.mouseLocation
            return .editable(anchor: CGRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 24))
        }
    }

    private func insert(_ suggestion: Suggestion, replacing count: Int) {
        // Last line of defense; the coordinator already refuses in secure contexts.
        guard !IsSecureEventInputEnabled() else {
            resetTyping()
            return
        }
        switch suggestion.payload {
        case .text(let text):
            TextInserter.replace(deleting: count, with: text)
            coordinator.didInsert(text, replacing: count)
        }
        picker.dismiss()
        frecency.record(suggestion.id)
        Self.encode(frecency, key: DefaultsKey.frecency)
    }

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
