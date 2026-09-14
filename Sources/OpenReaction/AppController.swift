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

    /// One `:token` from its colon until it ends. Holds what was learned about
    /// the focused field when the colon was typed.
    private struct Session {
        let tokenID: Int
        var isBlocked: Bool
        /// AppKit global coordinates, nil until the accessibility lookup returns.
        var anchor: CGRect?
    }

    @ObservationIgnored private let provider: any SuggestionProvider
    @ObservationIgnored private let picker = PickerPanelController()
    @ObservationIgnored private let locator = CaretLocator()
    @ObservationIgnored private var tap: KeyboardTap?
    @ObservationIgnored private var machine = TriggerMachine()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var frecency: Frecency
    /// Which emoji data is in use, for About and diagnostics.
    @ObservationIgnored let dataSourceSummary: String
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let minimumQueryLength = 2

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
        exclusions = Self.decode(AppExclusions.self, key: DefaultsKey.exclusions) ?? AppExclusions()
    }

    func start() {
        tap = KeyboardTap { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        picker.onVisibilityChange = { [weak self] frame in
            self?.tap?.setPicker(visible: frame != nil, quartzFrame: frame)
        }
        picker.model.onChoose = { [weak self] index in
            guard let self, self.picker.model.suggestions.indices.contains(index) else { return }
            self.picker.model.selectedIndex = index
            self.commitSelection()
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
        switch event.input {
        case .text(let text):
            apply(machine.handle(.text(text)))
        case .backspace:
            apply(machine.handle(.backspace))
        case .reset:
            resetTyping()
        case .ignore:
            break
        case .movePrevious, .moveNext:
            if picker.isVisible {
                picker.moveSelection(by: event.input == .movePrevious ? -1 : 1)
            } else {
                giveBack(event)
                resetTyping()
            }
        case .confirm:
            if picker.isVisible {
                commitSelection()
            } else {
                giveBack(event)
                resetTyping()
            }
        case .escape:
            if picker.isVisible {
                apply(machine.handle(.dismiss))
            } else {
                giveBack(event)
                resetTyping()
            }
        }
    }

    /// The tap swallowed a key because the picker looked visible, but it closed
    /// in the meantime. Send the key on so the user's keystroke is not lost.
    private func giveBack(_ event: TapEvent) {
        if event.swallowed {
            TextInserter.repost(keyCode: event.keyCode)
        }
    }

    private func resetTyping() {
        machine.handle(.reset)
        session = nil
        picker.dismiss()
    }

    private func apply(_ output: TriggerMachine.Output) {
        if let shortcode = output.completedShortcode {
            let blocked = session?.isBlocked ?? isBlockedNow()
            session = nil
            picker.dismiss()
            if !blocked, let suggestion = provider.exactMatch(for: shortcode) {
                insert(suggestion, replacing: shortcode.count + 2)
            }
            return
        }
        guard let token = output.token, !token.isDismissed else {
            session = nil
            picker.dismiss()
            return
        }
        if session?.tokenID != token.id {
            beginSession(tokenID: token.id)
        }
        refreshPicker()
    }

    // MARK: - Session

    private func isBlockedNow() -> Bool {
        IsSecureEventInputEnabled() || exclusions.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func beginSession(tokenID: Int) {
        let blocked = isBlockedNow()
        session = Session(tokenID: tokenID, isBlocked: blocked, anchor: nil)
        guard !blocked else { return }
        Task {
            let info = await locator.focusInfo()
            didLocateFocus(info, tokenID: tokenID)
        }
    }

    private func didLocateFocus(_ info: FocusInfo, tokenID: Int) {
        guard var current = session, current.tokenID == tokenID else { return }
        if info.isSecureField {
            current.isBlocked = true
        } else {
            current.anchor = anchorRect(for: info.anchor)
        }
        session = current
        refreshPicker()
    }

    private func anchorRect(for anchor: FocusInfo.Anchor) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        switch anchor {
        case .caret(let rect):
            return PanelPlacement.appKitRect(fromQuartz: rect, primaryScreenHeight: primaryHeight)
        case .element(let frame):
            let rect = PanelPlacement.appKitRect(fromQuartz: frame, primaryScreenHeight: primaryHeight)
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        case .none:
            // Below the pointer's hot spot, clear of the arrow itself.
            let mouse = NSEvent.mouseLocation
            return CGRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 24)
        }
    }

    private func refreshPicker() {
        guard let session, !session.isBlocked, let anchor = session.anchor,
              let token = machine.current.token, token.id == session.tokenID, !token.isDismissed,
              token.query.count >= Self.minimumQueryLength
        else {
            picker.dismiss()
            return
        }
        let suggestions = provider.suggestions(for: token.query, usage: frecency.scores(), limit: PickerMetrics.maxItems)
        guard !suggestions.isEmpty else {
            picker.dismiss()
            return
        }
        picker.present(suggestions, caret: anchor)
    }

    private func commitSelection() {
        guard let suggestion = picker.selectedSuggestion, let token = machine.current.token else {
            resetTyping()
            return
        }
        insert(suggestion, replacing: token.typedLength)
    }

    private func insert(_ suggestion: Suggestion, replacing count: Int) {
        guard !IsSecureEventInputEnabled() else { return }
        switch suggestion.payload {
        case .text(let text):
            TextInserter.replace(deleting: count, with: text)
            machine.handle(.replaced(count: count, with: text))
        }
        session = nil
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
