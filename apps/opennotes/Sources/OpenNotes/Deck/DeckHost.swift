import AppKit
import OpenNotesCore

/// Which displays host a deck, from the Display setting and the screens,
/// and one controller per host. Follows display changes, the settings and
/// the notes; on "the display with the pointer" the deck moves with the
/// pointer, checked twice a second (no monitor: `NSEvent.mouseLocation`).
final class DeckHost {
    private let model: AppModel
    private let preferences: Preferences
    private let showAllNotes: () -> Void
    private(set) var controllers: [CGDirectDisplayID: DeckPanelController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pointerTimer: Timer?

    init(model: AppModel, preferences: Preferences, showAllNotes: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.showAllNotes = showAllNotes
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observeChanges({ [preferences] in _ = preferences.side; _ = preferences.display }, onChange: { [weak self] in self?.settingsChanged() })
        observeChanges({ [model] in _ = model.revision; _ = model.readOnly }, onChange: { [weak self] in self?.notesChanged() })
        rebuild()
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            pointerTimer?.invalidate()
        }
    }

    /// The display names hosting a deck, for diagnostics.
    var hostedDisplayNames: [String] {
        controllers.keys.sorted().compactMap { ScreenCatalog.screen(for: $0)?.localizedName }
    }

    var stateDescription: String {
        controllers.values.map { controller in
            switch controller.state {
            case .pill: "pill"
            case .fan: "fan"
            case .open(let id, let editing): "open \(id.rawValue)\(editing ? " (editing)" : "")"
            }
        }.joined(separator: ", ")
    }

    /// The hotkey: a new note on the deck the pointer is on, else the first.
    func hotkey() {
        primaryController?.handle(.hotkey)
    }

    /// All Notes' Open, and the menu.
    func open(_ id: NoteID) {
        primaryController?.handle(.openRequested(id))
    }

    func closeAll() {
        for controller in controllers.values where controller.isOpen { controller.handle(.clickedOutside) }
    }

    /// Saves every open note (quit, folder change).
    func saveAll() {
        for controller in controllers.values where controller.isOpen { controller.handle(.escape) }
    }

    private var primaryController: DeckPanelController? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), let id = ScreenCatalog.displayID(of: screen), let controller = controllers[id] {
            return controller
        }
        return controllers.sorted { $0.key < $1.key }.first?.value
    }

    /// Re-reads the screens; keeps controllers whose display is still a
    /// host, tears down the others (saving an open note), makes new ones.
    func rebuild() {
        let hosts = Self.hosts(for: preferences.display, screens: NSScreen.screens)
        for (id, controller) in controllers where hosts[id] == nil {
            controller.tearDown()
            controllers[id] = nil
        }
        for (id, screen) in hosts {
            if let existing = controllers[id] {
                existing.update(screen: screen)
            } else {
                controllers[id] = DeckPanelController(displayID: id, screen: screen, model: model, preferences: preferences, showAllNotes: showAllNotes)
            }
        }
        pointerTimer?.invalidate()
        pointerTimer = nil
        if preferences.display == .pointer {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followPointer() }
            }
        }
    }

    /// The screens to host on: the main one, the pointer's, or every one.
    static func hosts(for display: DeckDisplay, screens: [NSScreen], pointer: CGPoint = NSEvent.mouseLocation) -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        switch display {
        case .main:
            if let screen = screens.first, let id = ScreenCatalog.displayID(of: screen) { result[id] = screen }
        case .pointer:
            let screen = screens.first { $0.frame.contains(pointer) } ?? screens.first
            if let screen, let id = ScreenCatalog.displayID(of: screen) { result[id] = screen }
        case .every:
            for screen in screens {
                if let id = ScreenCatalog.displayID(of: screen) { result[id] = screen }
            }
        }
        return result
    }

    private func followPointer() {
        let wanted = Self.hosts(for: .pointer, screens: NSScreen.screens)
        guard Set(wanted.keys) != Set(controllers.keys) else { return }
        // An open note stays where it is being written.
        guard !controllers.values.contains(where: \.isOpen) else { return }
        rebuild()
    }

    private func settingsChanged() {
        rebuild()
        for controller in controllers.values { controller.settingsChanged() }
    }

    private func notesChanged() {
        for controller in controllers.values { controller.notesChanged() }
    }
}

/// What `NSScreen` says about the displays.
enum ScreenCatalog {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == display }
    }
}
